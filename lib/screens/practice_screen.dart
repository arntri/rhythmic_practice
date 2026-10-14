import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../app/orientation.dart';
import '../data/models.dart';
import '../data/practice_repository.dart';
import '../metronome/metronome_engine.dart';
import '../practice/mit_sequence.dart';
import '../practice/practice_controller.dart';
import '../practice/step_timing.dart';
import '../services/attempt_scoring.dart';
import '../services/guide_player.dart';
import '../services/melody_hummer.dart';
import '../services/mic_capture.dart';
import '../services/photo_store.dart';
import '../services/sync_service.dart';
import 'caregiver_panel.dart';
import 'level_up_screen.dart';
import 'practice_view.dart';

/// Runs a practice session: loads the session's phrases from the database,
/// wires the metronome engine and audio guide/mic capture to the
/// [PracticeController] state machine, and renders the live UI via
/// [PracticeView], including the caregiver's verdict dock.
class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key});

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen>
    with SingleTickerProviderStateMixin {
  final _repository = PracticeRepository();
  final GuidePlayer _guide = GuidePlayer();

  /// Hums a phrase's melody before its words (MIT step 1). Synthesized on the
  /// spot from the phrase's syllable count + stressed syllable — no recording,
  /// so it works for any phrase in any language.
  final MelodyHummer _hummer = MelodyHummer();
  final MicCapture _mic = MicCapture();
  final AttemptScoring _scoring = AttemptScoring();
  final PhotoStore _photos = PhotoStore();

  MetronomeEngine? _engine;
  PracticeController? _controller;
  Map<int, String> _phraseText = {};
  Map<int, String?> _guideClip = {};
  // Confirmed syllable-nucleus timings per phrase — used to align the recorded
  // guide's pacing to the beat (Fix 3).
  Map<int, List<int>> _guideNuclei = {};
  // The probe question per phrase (MIT step 5): the text to speak and an optional
  // recorded clip. Both may be null → the step plays a generic prompt.
  Map<int, String?> _probeText = {};
  Map<int, String?> _probeClip = {};
  // The slow-spoken (Sprechgesang) clip per phrase — the same phrase said, not
  // sung, with its rhythm intact. Null until one is recorded, in which case the
  // step falls back to the built-in voice.
  Map<int, String?> _sprechClip = {};
  // Melody cue data (item 9): confirmed syllable count + caregiver-designated
  // high-note syllable per phrase, for the on-screen high–low contour.
  Map<int, int> _syllableCount = {};
  Map<int, int?> _stressIndex = {};
  // The caregiver's session tempo (BPM). ONE tempo for the session: MIT intones
  // slowly and stays there, so tempo is a property of the method, not a support
  // dial that moves with performance (DEPRECATIONS.md §3).
  int _baseBpm = 60;
  // Decrypted name-card photos by phrase id (therapy addendum §6), for display.
  Map<int, Uint8List> _photo = {};
  // The PATIENT's MIT level for this session — it selects the step sequence every
  // item runs, and it is the only thing progression carries between sessions.
  MitLevel _level = MitLevel.two;
  String? _sessionId;
  String? _profileId;
  String? _error;
  // The caregiver's sound setting, so we can restore it after muting the tick
  // during capture (so the metronome isn't recorded — therapy addendum §5).
  bool _soundPreference = true;
  // Whether the app may raise the patient's level on its own once the criterion
  // is met (caregiver setting). Within a session nothing is auto-anything — the
  // sequence is fixed by MIT and always runs in full.
  bool _autoProgressEnabled = true;
  // How the target's visual is shown (picture / word / both).
  TargetDisplay _targetDisplay = TargetDisplay.picture;
  // Caregiver guide-speed multiplier (1.0 normal; lower = slower words).
  double _playbackSpeed = 1.0;
  // Presenter demo mode: shows the in-session step picker (set in settings).
  bool _demoModeEnabled = false;
  // Bumped each time a reference prompt (re)starts, so a delayed advance queued
  // by a PREVIOUS prompt can't end the current one — matters when the demo level
  // picker re-runs the word mid-prompt (see [_advanceAfter] / [_setDemoRung]).
  int _promptGen = 0;

  // --- Per-step timing knobs -----------------------------------------------
  // The values themselves live in lib/practice/step_timing.dart — they are
  // protocol numbers (above all the six-second delayed repeat), so they are kept
  // where they can be read and tested rather than buried in this screen.

  /// Safety cap (beats) on how long a reference prompt may run before the
  /// controller moves on by itself. The screen normally drives the advance per
  /// rung, so this only fires if that never arrives — but it must comfortably
  /// outlast the longest legitimate prompt, which is now a seven-syllable phrase
  /// (7 beats) followed by the six-second delayed-repeat hold (6 beats).
  static const _guideSafetyBeats = 20;

  /// Tick loudness for the soft beat heard UNDER the spoken word at the unison
  /// steps — quiet enough not to fight the model, loud enough to give the
  /// one-beat-per-syllable pulse. (No mic is open at a unison step, so it can't
  /// bleed into a recording.)
  static const _kUnisonTickVolume = 0.35;

  /// WSOLA elongation for the user's **recorded** clip (pitch-preserving). The
  /// recording is already a human speaking deliberately, so it needs only modest
  /// stretching — say-it-together steps most, the solo answer least. Tuned by
  /// feel.
  double _recordedStretch(MitStep step) {
    if (step.isUnison) return 2.8; // say it together — slowest
    if (step == MitStep.immediateRepeat || step == MitStep.delayedRepeat) {
      return 2.2; // repeat-after
    }
    return 1.8;
  }

  /// Slow-down basis for the **built-in (device TTS)** voice. Kept slower than
  /// the recorded path — the synthetic voice runs fast otherwise — so the user
  /// can still keep pace. (Larger value → slower TTS; see [GuidePlayer.play].)
  double _ttsStretch(MitStep step) {
    if (step.isUnison) return 3.8;
    if (step == MitStep.immediateRepeat || step == MitStep.delayedRepeat) {
      return 3.0;
    }
    return 2.4;
  }

  // The per-step elongation, scaled by the caregiver's playback-speed setting:
  // a slower speed (0.5×) elongates more (≈2× the stretch). Guarded against 0.
  double get _speed => _playbackSpeed <= 0 ? 1.0 : _playbackSpeed;
  double _recordedStretchFor(MitStep step) => _recordedStretch(step) / _speed;
  double _ttsStretchFor(MitStep step) => _ttsStretch(step) / _speed;

  // One beat period (ms) at the session tempo — the warp target (one syllable per
  // beat) and the metronome's own period; they must match so the warped audio
  // rides the pulse.
  int get _beatPeriodMs => (60000 / _baseBpm).round();

  // Whether the recorded guide for [id] can be beat-warped (a real clip + at
  // least two confirmed nuclei to space across the beats).
  bool _canBeatWarp(int id) =>
      _guideClip[id] != null && (_guideNuclei[id]?.length ?? 0) >= 2;

  // Play the guide for [id], starting on the next beat so the warped
  // one-syllable-per-beat audio lines up with the metronome pulse. When the clip
  // can't be warped (no clip / too few nuclei) it falls back to the per-step
  // uniform elongation, played immediately. [cutLast] drops the final syllable
  // (the fading-unison step). NOTE: the beat-warped path is paced by the
  // metronome tempo, so the caregiver playback-speed only applies to the
  // uniform/TTS fallback.
  void _playGuide(
    int id,
    MitStep step, {
    required void Function() onComplete,
    void Function()? onStart,
    bool cutLast = false,
  }) {
    final canWarp = _canBeatWarp(id);
    final beatMs = _beatPeriodMs;
    void doPlay() {
      // Fires when the model ACTUALLY starts — after the wait for the next beat,
      // not when playback was requested. The tapping window opens here, so the
      // caregiver isn't cued to tap through the beat we spend lining up.
      onStart?.call();
      _guide.play(
        clipPath: _guideClip[id],
        text: _phraseText[id] ?? '',
        stretch: _recordedStretchFor(step),
        ttsStretch: _ttsStretchFor(step),
        beatNucleiMs: canWarp ? _guideNuclei[id] : null,
        beatPeriodMs: canWarp ? beatMs : null,
        cutLastSyllable: cutLast,
        onComplete: onComplete,
      );
    }

    _guideStartTimer?.cancel();
    final engine = _engine;
    if (canWarp && engine != null && engine.isRunning) {
      // Time to the next beat from the current phase (best-effort; the warp keeps
      // the internal syllable-to-beat spacing locked regardless of onset jitter).
      final remainMs = ((1 - engine.currentPhase) * beatMs).round().clamp(
        0,
        beatMs,
      );
      _guideStartTimer = Timer(
        Duration(milliseconds: remainMs),
        () => mounted ? doPlay() : null,
      );
    } else {
      doPlay();
    }
  }

  /// Fallback probe spoken when the caregiver hasn't set a question for a phrase
  /// — keeps the step running (never blocks) while still cueing a solo answer. A
  /// configured [PracticePhrase.probeQuestionText] always wins.
  static const _genericProbe = 'Your turn — say the word.';

  // Play the probe question for [id]: the recorded clip if present, else TTS of
  // the caregiver's probe text, else a gentle generic prompt. Unlike the guide it
  // is NOT beat-warped (it's a question, not the target word to pace to the beat).
  void _playProbe(int id, {required void Function() onComplete}) {
    _guideStartTimer?.cancel();
    _guide.play(
      clipPath: _probeClip[id],
      text: (_probeText[id]?.trim().isNotEmpty ?? false)
          ? _probeText[id]!
          : _genericProbe,
      stretch: 1.0, // natural pace — a question isn't elongated like the word
      ttsStretch: 1.2, // just slightly slow for clarity
      onComplete: onComplete,
    );
  }

  // Play the slow-spoken model for the Sprechgesang step: the caregiver's
  // recorded clip if there is one, else the built-in voice saying the phrase.
  //
  // Deliberately NOT beat-warped onto the melody the way the intoned guide is.
  // Sprechgesang keeps MIT's rhythm and drops its tune, so the pulse is carried
  // by the metronome and the tapping hand rather than by a sung contour — which
  // is the whole content of this step. The tick stays audible underneath for the
  // same reason.
  void _playSprechgesang(int id, {required void Function() onComplete}) {
    _guideStartTimer?.cancel();
    _guide.play(
      clipPath: _sprechClip[id],
      text: _phraseText[id] ?? '',
      // Slow and deliberate, but nowhere near the elongation the intoned steps
      // use — by now the target is ordinary speech, only clearer.
      stretch: 1.6 / _speed,
      ttsStretch: 1.8 / _speed,
      onComplete: onComplete,
    );
  }

  int _prepCountdown =
      0; // >0 while the unison "get ready" countdown is showing
  Timer? _prepTimer;

  /// Which pass of the per-phrase hum is playing (0-based), or -1 when not
  /// humming. The view shows the second pass as "again" so it doesn't read as a
  /// glitch.
  int _humPass = -1;
  Timer? _guideStartTimer; // delays guide playback to the next beat (beat-sync)

  @override
  void initState() {
    super.initState();
    _setUp();
  }

  Future<void> _setUp() async {
    try {
      final profile = await _repository.getProfile();
      _soundPreference = profile.soundEnabled;
      _autoProgressEnabled = profile.autoProgressEnabled;
      _demoModeEnabled = profile.demoModeEnabled;
      _targetDisplay = profile.targetDisplay;
      _playbackSpeed = profile.playbackSpeed;
      // The patient's level selects the step sequence every item will run.
      _level = profile.mitLevel;
      _mic.silenceWindow = Duration(milliseconds: profile.captureSilenceMs);
      final active = await _repository.getActivePhrases();
      // A session is at most `session_phrase_limit` phrases.
      final phrases = active.take(profile.sessionPhraseLimit).toList();
      if (phrases.isEmpty) {
        setState(() => _error = 'No active phrases. Enable some in settings.');
        return;
      }
      _phraseText = {for (final p in phrases) p.phraseId: p.phraseText};
      // Recorded guide clip per phrase (null → the guide falls back to TTS).
      _guideClip = {for (final p in phrases) p.phraseId: p.guideClipPath};
      // Confirmed syllable timings per phrase (for voice-to-beat alignment).
      _guideNuclei = {for (final p in phrases) p.phraseId: p.guideNucleiMs};
      // R7 probe question per phrase (text + optional recorded clip). Null/absent
      // → R7 plays a gentle generic prompt (never blocks — item 11).
      _probeText = {for (final p in phrases) p.phraseId: p.probeQuestionText};
      _probeClip = {
        for (final p in phrases) p.phraseId: p.probeQuestionClipPath,
      };
      // Melody cue (item 9): syllable count comes from the confirmed guide nuclei
      // (falls back to the stored count); the high-note syllable is the caregiver
      // designation. Both may be absent → the practice screen shows no cue.
      _syllableCount = {
        for (final p in phrases)
          p.phraseId: p.guideNucleiMs.isNotEmpty
              ? p.guideNucleiMs.length
              : p.syllableCount,
      };
      _stressIndex = {for (final p in phrases) p.phraseId: p.stressIndex};
      _sprechClip = {
        for (final p in phrases) p.phraseId: p.sprechgesangClipPath,
      };
      _baseBpm = profile.metronomeBpm;
      _profileId = profile.profileId;
      debugPrint(
        '[MIT] session opens at Level ${_level.roman} — sequence: '
        '${stepsFor(_level).map((s) => s.name).join(' → ')}',
      );
      // Decrypt any name-card photos up front for display (best-effort — a
      // missing/corrupt photo just falls back to the text card).
      _photo = {};
      for (final ph in phrases) {
        final path = ph.photoPath;
        if (path != null) {
          final bytes = await _photos.decrypt(path);
          if (bytes != null) _photo[ph.phraseId] = bytes;
        }
      }

      // One session row groups all of this run's attempts.
      final sessionId = await _repository.createSession(profile.profileId);
      _sessionId = sessionId;

      // ONE entry per item. Every item runs its level's whole step sequence in
      // this sitting, and how many productions that takes is decided step by step
      // ([RepRule]) — so reps are no longer baked into the session list the way
      // the old 3-rep block was.
      final controller = PracticeController(
        phraseIds: [for (final p in phrases) p.phraseId],
        level: _level,
        // Generous safety cap: the screen normally drives the advance per step
        // (below); this only fires if that never arrives. In demo mode we lift it
        // so nothing auto-advances — the presenter holds a step until they pick
        // another from the demo bar.
        guideBeats: _demoModeEnabled ? (1 << 30) : _guideSafetyBeats,
        onEnterReferencePrompt: _onEnterReference,
        onEnterWarmUpHum: _onEnterWarmUpHum,
        // MIT step 1: hum this phrase's melody twice before its words appear.
        onEnterPhraseHum: _onEnterPhraseHum,
        onEnterInputCapture: _onEnterCapture,
        // Capture ended (silence or beat timeout): stop the mic.
        onLeaveInputCapture: (_) => _mic.stop(),
        // Verdict state (every step): restore the tick, stop any guide.
        onEnterSystemTransition: _onEnterCaregiver,
        // A break: everything stops, the beat included.
        onEnterRest: _onEnterRest,
        // The caregiver opened their panel — same, for the same reason.
        onEnterPaused: _onEnterRest,
        // Persist each finished attempt to the local database (and try to sync).
        onAttemptComplete: (result) => _saveAttempt(result),
        // The two moves that need explaining to the caregiver as they happen.
        onStepBackedUp: _onStepBackedUp,
        onItemSetAside: _onItemSetAside,
      );

      final engine =
          MetronomeEngine(
              vsync: this,
              bpm: profile.metronomeBpm,
              soundEnabled: profile.soundEnabled,
              visualEnabled: profile.visualEnabled,
              hapticEnabled: profile.hapticEnabled,
              onBeat: controller.onBeat, // the heartbeat that drives the FSM
            )
            ..emphasizeBeat =
                true; // the session opens on "tap the beat" — emphasise it

      // Per-session ambient calibration (therapy §5): sample the room's noise
      // floor so silence-detection adapts to the environment. Runs here, before
      // the metronome/guide start, so nothing else is making sound. Best-effort —
      // on failure we keep the default threshold.
      try {
        final tmp = await getTemporaryDirectory();
        await _mic.calibrateAmbient(
          rawPath: p.join(tmp.path, 'ambient_cal.wav'),
        );
        // Let the audio session settle back to playback after recording, so the
        // first guide isn't swallowed by a lingering record-mode session.
        await Future<void>.delayed(const Duration(milliseconds: 350));
      } catch (e) {
        debugPrint('Ambient calibration skipped: $e');
      }

      setState(() {
        _controller = controller;
        _engine = engine;
      });

      controller.addListener(_onControllerChanged);
      controller.start();
      engine.start();
    } catch (e) {
      setState(() => _error = 'Could not start practice: $e');
    }
  }

  /// Per-item hum (State_1c) — MIT's step 1, the one step that is never judged.
  /// Before the item's words appear, its melody is hummed twice, no words, while
  /// the caregiver taps. The tick stays audible underneath: the hum rides one
  /// syllable per beat, and the beat is what the tapping is synchronised to.
  ///
  /// The controller's beat-based cap is only a safety net; we end the state the
  /// moment the synthesized melody finishes.
  void _onEnterPhraseHum(int id) {
    // An item that opens on the hum is also the first thing after a break, so
    // the beat has to come back here too.
    final engine = _engine;
    if (engine != null && !engine.isRunning) engine.start();
    _startHum(id, onDone: _controller?.endPhraseHum);
  }

  // Session warm-up, hum phase (State_1b): the beat is the whole point, so keep
  // the tick full and emphasise it while the user hums along. The controller
  // auto-advances into the first item after its warm-up beats.
  void _onEnterWarmUpHum() {
    _engine?.tickVolume = 1.0;
    _engine?.soundEnabled = _soundPreference;
    _engine?.emphasizeBeat = true;
  }

  // Play [id]'s melody (no words) and call [onDone] when it finishes. Shared by
  // the unjudged hum step and Level I's hum-in-unison step — the audio is the
  // same melody; what differs is whether a verdict follows.
  void _startHum(int id, {required void Function()? onDone}) {
    _guideStartTimer?.cancel();
    _guide.stop();
    _engine?.tickVolume = _kUnisonTickVolume; // soft, under the hum
    _engine?.soundEnabled = _soundPreference;
    _engine?.emphasizeBeat = false;
    if (mounted) setState(() => _humPass = 0);
    // The hum IS a production of the phrase — MIT taps the hand through it, so
    // the window is open for the whole hum (including the beat of rest between
    // the two passes, which is a breath in one gesture, not a stop).
    _controller?.beginProduction();

    _hummer.hum(
      // A phrase with no confirmed guide yet still gets a hum: one note per
      // beat is a legitimate melody for a single-syllable target.
      syllableCount: _syllableCount[id] ?? 1,
      stressIndex: _stressIndex[id] ?? 0,
      beatPeriodMs: _beatPeriodMs,
      onPass: (pass) {
        if (mounted) setState(() => _humPass = pass);
      },
      onComplete: () {
        if (!mounted) return;
        setState(() => _humPass = -1);
        _controller?.endProduction(); // hand rests until the next production
        onDone?.call();
      },
    );
  }

  // The prompt for a JUDGED step. Every branch ends the same way — by handing
  // control back to the controller, which routes to the mic or straight to the
  // caregiver's verdict depending on whether the step yields a clean solo
  // production.
  //
  // What changes between steps is how much of the phrase the person is given
  // before they produce it: the model sung with them, the model fading under
  // them, the model then a breath, the model then six seconds of silence, or
  // nothing but a question. That gradient IS the therapy — it is why the step,
  // not a stored rung, is what this method switches on.
  void _onEnterReference(int id) {
    // New prompt: invalidate any advance still pending from the previous one.
    if (_humPass != -1) setState(() => _humPass = -1);
    _promptGen++;
    // Carrying on from a break restarts the beat that [_onEnterRest] stopped.
    final engine = _engine;
    if (engine != null && !engine.isRunning) engine.start();
    final step = _controller?.currentStep ?? MitStep.intoneUnison;
    // Unison steps keep a SOFT tick under the spoken word so the user hears one
    // beat per syllable (safe — no mic there). The steps that record mute the
    // tick: the model is solo and the mic opens, so a tick would bleed in.
    _engine?.tickVolume = _kUnisonTickVolume;
    _engine?.soundEnabled = step.isUnison ? _soundPreference : false;
    _engine?.emphasizeBeat = false; // beat emphasis is the warm-up's job now

    switch (step) {
      case MitStep.humUnison:
        // Level I's own production: hum the melody WITH them, then the verdict.
        // No words are asked for, so nothing here can be failed for not speaking.
        _startHum(id, onDone: () => _advanceAfter(unisonTailMs));
      case MitStep.intoneUnison:
      case MitStep.unisonFading:
        // "Say it together": show the word, count down so the user is ready,
        // then play the model for them to produce along with (no recording).
        _startUnisonPrep(id, step);
      case MitStep.immediateRepeat:
      case MitStep.delayedRepeat:
        // Listen to the model (beat-warped), then the hold, then the mic. The
        // tapping runs with the model and STOPS when it ends — the breath and
        // the six-second retrieval silence are gaps, and MIT's hand rests in the
        // gaps. It starts again when the mic opens and she speaks.
        _playGuide(
          id,
          step,
          onStart: () => _controller?.beginProduction(),
          onComplete: () {
            _controller?.endProduction();
            _advanceAfter(afterModelMs(step));
          },
        );
      case MitStep.probeQuestion:
        // MIT's step 5, and the only step that asks her to *use* the phrase:
        // play the question, then a breath, then the mic. No model of the answer
        // — that is the point.
        _playProbe(id, onComplete: () => _advanceAfter(repeatBreathMs));
      case MitStep.sprechgesang:
        // The bridge out of song. A spoken model with the rhythm intact, then a
        // breath, then the mic. The tick stays ON here (unlike the other
        // recording steps) right up to the model ending, because the pulse is
        // what is left holding the phrase together once the tune is gone —
        // [_onEnterCapture] mutes it before the mic opens so it can't bleed in.
        _engine?.tickVolume = _kUnisonTickVolume;
        _engine?.soundEnabled = _soundPreference;
        _controller?.beginProduction();
        _playSprechgesang(
          id,
          onComplete: () {
            _controller?.endProduction();
            _advanceAfter(afterModelMs(step));
          },
        );
      case MitStep.spokenProduction:
        // The last thing MIT asks for, and the point of all of it: the phrase
        // said the way anyone would say it. Nothing is played — no tune, no
        // spoken model, no question. A brief get-ready, then the mic.
        _advanceAfter(spokenPromptMs);
      case MitStep.humMelody:
        // Never reached (the hum has its own state); a safety net if it ever is.
        _advanceAfter(unisonTailMs);
    }
  }

  // Unison prep countdown, then play the model and advance to the verdict.
  void _startUnisonPrep(int id, MitStep step) {
    _prepTimer?.cancel();
    setState(() => _prepCountdown = unisonPrepSeconds);
    _prepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_prepCountdown <= 1) {
        t.cancel();
        setState(() => _prepCountdown = 0);
        // Say-it-together (beat-warped, soft tick under it). The fading step
        // drops the final syllable — the guide player places the cut on the
        // warped timeline from the confirmed nuclei — so the user ends it alone.
        // Unison is one continuous production: she sings WITH the model and is
        // often still finishing after it stops (that's what the tail is for), so
        // the window stays open past completion and is closed by the move to the
        // verdict. The count-in above is deliberately outside it — nothing is
        // being produced yet.
        _playGuide(
          id,
          step,
          cutLast: step == MitStep.unisonFading,
          onStart: () => _controller?.beginProduction(),
          onComplete: () => _advanceAfter(unisonTailMs),
        );
      } else {
        setState(() => _prepCountdown -= 1);
      }
    });
  }

  // Open the mic. Only reached at a step that yields a clean solo production,
  // and the guide has already finished, so there's no playback to contend with.
  void _onEnterCapture(int id) {
    _guideStartTimer?.cancel();
    _guide.stop();
    _engine?.soundEnabled = false;
    _engine?.emphasizeBeat = false;
    // Her own production — the one MIT cares most about tapping through.
    _controller?.beginProduction();
    _startCapture();
  }

  // A break. The beat stops with everything else: a pulse still running under a
  // rest makes it a pause in the session rather than a rest from it, and the
  // caregiver is being asked to put the tapping hand down too.
  void _onEnterRest() {
    _prepTimer?.cancel();
    _guideStartTimer?.cancel();
    _guide.stop();
    _hummer.stop();
    _mic.stop();
    _engine?.stop();
    if (mounted) {
      setState(() {
        _prepCountdown = 0;
        _humPass = -1;
      });
    }
  }

  // Caregiver-verdict state: restore the tick (full volume — the soft unison
  // tick only applies under the word) and stop any guide still playing.
  void _onEnterCaregiver() {
    _guideStartTimer?.cancel();
    _engine?.soundEnabled = _soundPreference;
    _engine?.tickVolume = 1.0;
    _engine?.emphasizeBeat = false;
    _guide.stop();
  }

  void _advanceAfter(int ms) {
    final gen = _promptGen;
    Future<void>.delayed(Duration(milliseconds: ms), () {
      // Drop the advance if the prompt was re-run in the meantime (demo picker),
      // so a stale timer can't cut the freshly-started prompt short.
      if (mounted && gen == _promptGen) _controller?.endReferencePrompt();
    });
  }

  // Open the mic for the current attempt. The clip auto-closes on ~4.5 s of
  // silence; when it does, we hand latency/duration/path to the controller and
  // end the capture state. Permission denial just leaves the attempt audio-free.
  Future<void> _startCapture() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final clips = Directory(p.join(dir.path, 'clips'));
      if (!await clips.exists()) await clips.create(recursive: true);
      final id = const Uuid().v4();
      await _mic.start(
        rawPath: p.join(clips.path, '$id.wav'),
        encryptedPath: p.join(clips.path, '$id.enc'),
        onClosed: (result) {
          _controller?.recordCaptureMetrics(
            latencyMs: result.latencyMs,
            durationMs: result.durationMs,
            audioPath: result.encryptedPath,
          );
          _controller?.endCapture();
        },
      );
    } catch (e) {
      debugPrint('Mic capture failed to start: $e');
    }
  }

  // Save a finished production, then opportunistically push to the cloud. Runs in
  // the background (the controller carries on as the session continues).
  Future<void> _saveAttempt(AttemptResult result) async {
    // Demo mode is strictly ephemeral: a live demonstration must never alter real
    // therapy history, so nothing is persisted — no attempt row, no daily rollup,
    // no sync.
    if (_demoModeEnabled) return;
    final sessionId = _sessionId;
    if (sessionId == null) return;

    try {
      final attemptId = await _repository.insertAttempt(
        sessionId: sessionId,
        phraseId: result.phraseId,
        evaluationLabel: result.evaluationLabel,
        tappingSynchronizationScore: result.syncScore,
        latencyMs: result.latencyMs,
        durationMs: result.durationMs,
        localEncryptedAudioPath: result.localEncryptedAudioPath,
        // v28: the MIT step this production was made at — the difficulty context
        // that replaced the ladder rung.
        stepAtAttempt: result.step.index,
        // v20 (item 16c): the metronome tempo this attempt was produced at — the
        // beat reference onset-vs-beat steadiness is measured against later.
        tempoBpm: _baseBpm,
      );
      // ML logging (item 16a): persist this production's RAW tap stream (touch-
      // down time + dwell + beat phase per tap), tied to the attempt/phrase/step.
      // The aggregate sync score on the attempt row can't reconstruct dwell or
      // inter-tap-interval variance — the fatigue detector's inputs — so the
      // un-aggregated stream has to be saved here at session time.
      await _repository.insertTapEvents(
        attemptId: attemptId,
        phraseId: result.phraseId,
        sessionId: sessionId,
        step: result.step,
        taps: result.taps,
      );
      // Phase 2B: score the clip against the phrase's recorded guide (similarity
      // + anchor) — only at steps that yield a clean solo production. A unison
      // step is contaminated by the model sounding aloud, and the hum isn't words.
      if (result.step.cleanCapture) {
        await _scoring.scoreAttempt(
          attemptId: attemptId,
          phraseId: result.phraseId,
          profileId: _profileId ?? '',
          encryptedAttemptPath: result.localEncryptedAudioPath,
          guideClipPath: _guideClip[result.phraseId],
          evaluationLabel: result.evaluationLabel,
        );
      }
      // Refresh today's metrics rollup (display-only) so it reflects this attempt
      // and re-syncs.
      await _repository.touchDailySummaryForToday(_profileId ?? '');
      // No-op unless signed in + consent granted.
      await SyncService(_repository).pushPending();
    } catch (e) {
      debugPrint('Failed to save/sync attempt: $e');
    }
  }

  // --- The two moves that need explaining ----------------------------------
  // Both are MIT's, both look like setbacks if left unannounced, and neither is
  // one. Each now gets a HELD STATE of its own on the patient's screen
  // (`PracticeState.backingUp` / `.itemSetAside`), so these callbacks are only
  // for the log — a snackbar on top of the screen that already says it would be
  // the same sentence twice.

  void _onStepBackedUp(MitStep from, MitStep to) =>
      debugPrint('[MIT] backed up ${from.name} → ${to.name}');

  void _onItemSetAside(int phraseId) => debugPrint(
    '[MIT] set aside phrase=$phraseId "${_phraseText[phraseId] ?? ''}"',
  );

  // --- Level advancement (the ONLY thing progression decides now) -----------

  /// Whether the end-of-session level check has already run, so the controller's
  /// listener can't fire it twice.
  bool _levelChecked = false;

  // Watch for the end of the session, then apply MIT's advancement criterion.
  void _onControllerChanged() {
    final controller = _controller;
    if (controller == null) return;
    if (controller.state != PracticeState.sessionComplete || _levelChecked) {
      return;
    }
    _levelChecked = true;
    unawaited(_evaluateLevel());
  }

  /// MIT's ~90% criterion, applied where MIT applies it: to the **person's
  /// level**, once the session is over.
  ///
  /// This is the whole of progression now. There is no per-word rung to raise,
  /// no syllable tier to gate, and no tempo to ease — within a session the
  /// sequence is fixed and always runs in full, and a failed step is answered in
  /// the moment by backing up rather than at the word's next appearance.
  Future<void> _evaluateLevel() async {
    if (_demoModeEnabled || !_autoProgressEnabled) return;
    final profileId = _profileId;
    if (profileId == null) return;
    try {
      final rates = await _repository.sessionPassRates(profileId);
      final advance = LevelCriterion.shouldAdvance(rates, current: _level);
      debugPrint(
        '[MIT] level gate: at ${_level.title}, '
        '${rates.length} judged sessions, '
        'last ${LevelCriterion.window} mean='
        '${_meanOfLastWindow(rates).toStringAsFixed(2)} '
        '(need ≥${LevelCriterion.passRate}) → advance=$advance',
      );
      if (!advance || !mounted) return;
      // The criterion is EVIDENCE, not a verdict. It changes the whole step
      // sequence from the next session on, and the person sitting beside the
      // patient knows things the app does not — so it is put to them, and
      // declining is a real answer rather than a link tucked underneath.
      final next = LevelCriterion.raised(_level);
      final accepted = await Navigator.of(context).push<bool>(
        LandscapePageRoute<bool>(
          builder: (routeContext) => LevelUpScreen(
            from: _level,
            to: next,
            onAccept: () => Navigator.of(routeContext).pop(true),
            onDecline: () => Navigator.of(routeContext).pop(false),
          ),
        ),
      );
      if (accepted != true) {
        debugPrint('[MIT] level advance declined; staying at ${_level.title}');
        return;
      }
      await _repository.updateProfile(mitLevel: next);
      _level = next;
    } catch (e) {
      debugPrint('Level check failed: $e');
    }
  }

  // Mean of the last [LevelCriterion.window] session rates, for the log line.
  double _meanOfLastWindow(List<double> rates) {
    if (rates.isEmpty) return 0;
    final recent = rates.length <= LevelCriterion.window
        ? rates
        : rates.sublist(rates.length - LevelCriterion.window);
    return recent.reduce((a, b) => a + b) / recent.length;
  }

  // --- Demo mode (presenter step picker) -----------------------------------
  // Jump the CURRENT item to [step] for a live demonstration, then re-run it so
  // the new step's behaviour (model playback, cues, stage tint) plays out at
  // once. Nothing is judged and nothing is written, so a demo never disturbs
  // real therapy history.
  //
  // Under the ladder this picked a rung the word would then sit at. There is no
  // such thing to pick now — so it picks a step of the sequence the item is
  // already running, which is the same gesture aimed at the real structure.
  void _setDemoStep(MitStep step) {
    final controller = _controller;
    if (controller == null) return;
    if (controller.currentStep == step) return; // already there
    // Cancel everything in flight from the prompt we're interrupting.
    _prepTimer?.cancel();
    _guideStartTimer?.cancel();
    _guide.stop();
    _hummer.stop();
    _mic.stop();
    setState(() {
      _prepCountdown = 0;
      _humPass = -1;
    });
    debugPrint(
      '[DEMO] jump phrase=${controller.currentPhraseId} '
      '"${_phraseText[controller.currentPhraseId]}" '
      '${controller.currentStep.name}→${step.name}',
    );
    controller.demoJumpToStep(step);
  }

  // The presenter's step picker: a compact row of this level's steps pinned
  // bottom-centre, only shown when demo mode is enabled in settings. The current
  // step is highlighted.
  Widget _demoBar(PracticeController controller) {
    final current = controller.currentStep;
    return Center(
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 10),
              child: Text(
                'DEMO · ${controller.level.roman}',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            // Exactly the steps this level runs — so a presenter jumps around
            // the real sequence, not a menu of stages that can't occur.
            for (final (i, step) in stepsFor(controller.level).indexed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _demoStepButton(
                  step,
                  ordinal: i + 1,
                  selected: step == current,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _demoStepButton(
    MitStep step, {
    required int ordinal,
    required bool selected,
  }) {
    return Material(
      color: selected ? Colors.white : Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: selected ? null : () => _setDemoStep(step),
        child: Tooltip(
          message: step.title,
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            child: Text(
              '$ordinal',
              style: TextStyle(
                color: selected ? Colors.black : Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _prepTimer?.cancel();
    _guideStartTimer?.cancel();
    _engine?.dispose();
    _controller?..removeListener(_onControllerChanged)
      ..dispose();
    _guide.dispose();
    _hummer.dispose();
    _mic.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Practice')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!),
          ),
        ),
      );
    }
    final engine = _engine;
    final controller = _controller;
    if (engine == null || controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: Stack(
        children: [
          PracticeView(
            engine: engine,
            controller: controller,
            phraseText: _phraseText,
            photoByPhrase: _photo,
            targetDisplay: _targetDisplay,
            syllableCountByPhrase: _syllableCount,
            stressIndexByPhrase: _stressIndex,
            humPass: _humPass,
            // The count-in is drawn inside the view now, so the phrase staff can
            // dim with it rather than a banner floating over an unchanged frame.
            countdown: _prepCountdown,
            probeQuestionByPhrase: _probeText,
            // The caregiver's way out, from anywhere in the session. Opening
            // the panel PAUSES the session (the panel does it, on the way in),
            // so the rotation into portrait is a real privacy boundary rather
            // than just a different screen.
            onCaregiverUnlock: () => Navigator.of(context).push(
              PortraitPageRoute<void>(
                builder: (_) => CaregiverPanel(
                  repository: _repository,
                  controller: controller,
                  phraseText: _phraseText,
                ),
              ),
            ),
          ),
          // Presenter step picker (demo mode only). Padded clear of the right-
          // edge caregiver verdict dock so the two never overlap.
          if (_demoModeEnabled)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.only(right: 160),
                  child: _demoBar(controller),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
