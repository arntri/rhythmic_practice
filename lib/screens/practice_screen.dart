import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../data/models.dart';
import '../data/practice_repository.dart';
import '../metronome/metronome_engine.dart';
import '../practice/mit_progression.dart';
import '../practice/practice_controller.dart';
import '../practice/progression.dart';
import '../services/attempt_scoring.dart';
import '../services/guide_player.dart';
import '../services/mic_capture.dart';
import '../services/photo_store.dart';
import '../services/sync_service.dart';
import 'practice_view.dart';
import 'settings_portal.dart';

/// Runs a practice session: loads the session's phrases from the database,
/// wires the metronome engine to the [PracticeController] state machine, and
/// renders the live UI via [PracticeView].
///
/// This is the Step 3 skeleton. The audio guide (Step 4) and microphone
/// (Step 5) are still placeholders inside the controller; the caregiver
/// Pass/Fail/Unsure buttons get their proper isolated dock in Step 7.
class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key});

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen>
    with SingleTickerProviderStateMixin {
  final _repository = PracticeRepository();
  final GuidePlayer _guide = GuidePlayer();
  final MicCapture _mic = MicCapture();
  final AttemptScoring _scoring = AttemptScoring();
  final PhotoStore _photos = PhotoStore();
  // Phase 3: the rules-based MIT progression controller (fixed 3-rep block).
  final MitProgression _mit = const MitProgression();

  MetronomeEngine? _engine;
  PracticeController? _controller;
  Map<int, String> _phraseText = {};
  Map<int, String?> _guideClip = {};
  // Confirmed syllable-nucleus timings per phrase — used to align the recorded
  // guide's pacing to the beat (Fix 3).
  Map<int, List<int>> _guideNuclei = {};
  // The caregiver's base session tempo (BPM); per-word tempo never exceeds it.
  int _baseBpm = MitProgression.defaultBpm;
  // Decrypted name-card photos by phrase id (therapy addendum §6), for display.
  Map<int, Uint8List> _photo = {};
  // SINGLE SOURCE OF TRUTH for the current rung (+ tier/tempo): the controller's
  // behavior, the on-screen stage, and the level-change announcement all read
  // the rung from here (via [_rungOf]). Tier + tempo come from the
  // progression_state table; `_blockLabels` accumulates the current 3-rep block.
  final Map<int, ProgressionState> _progState = {};
  final Map<int, List<int>> _blockLabels = {};
  String? _sessionId;
  String? _profileId;
  String? _error;
  // The caregiver's sound setting, so we can restore it after muting the tick
  // during capture (so the metronome isn't recorded — therapy addendum §5).
  bool _soundPreference = true;
  // Whether the auto-progression engine may move rungs (caregiver setting).
  bool _autoProgressEnabled = true;
  // How the target's visual is shown (picture / word / both).
  TargetDisplay _targetDisplay = TargetDisplay.picture;
  // Caregiver guide-speed multiplier (1.0 normal; lower = slower words).
  double _playbackSpeed = 1.0;
  // Caregiver "comfort cap" (low-energy days): the highest rung the auto-
  // progression may advance to this session, or null for no cap.
  Rung? _sessionRungCap;
  // Presenter demo mode: shows the in-session level picker (set in settings).
  bool _demoModeEnabled = false;
  // Bumped each time a reference prompt (re)starts, so a delayed advance queued
  // by a PREVIOUS prompt can't end the current one — matters when the demo level
  // picker re-runs the word mid-prompt (see [_advanceAfter] / [_setDemoRung]).
  int _promptGen = 0;

  // --- Per-rung timing knobs (tuned by feel on-device) ---------------------
  /// Unison (r2/r3): pause after the model finishes before the caregiver verdict,
  /// so the user can finish saying it together (no separate recording).
  static const _unisonTailMs = 1800;

  /// Repeat (r4): breath after the model finishes before the mic opens.
  static const _repeatBreathMs = 1200;

  /// Delayed repeat (r5): longer pause after the model before the mic opens.
  static const _delayedRepeatMs = 2200;

  /// Hum (r1): how long the user hums to the beat before the verdict — long
  /// enough to actually settle into several beats (not flash by).
  static const _humMs = 8000;

  // --- R0 (tap-along exposure window) — tunable -----------------------------
  /// Length of ONE r0 tap window. The user gets a window to tap in time; if the
  /// tap-sync threshold isn't met within it, they get a SECOND window of equal
  /// length, then r0 promotes regardless. r0 NEVER blocks (the no-trap floor).
  static const _r0TapWindowMs = 6000;

  /// Tap-sync score (0–1) within an r0 window that counts as "in time" — meeting
  /// it on the FIRST window skips the second. It only decides whether a second
  /// window is offered; it can never permanently hold the user on r0.
  static const _r0TapSyncThreshold = 0.5;

  /// Solo (r6): brief "get ready" the word shows before the mic opens.
  static const _soloPromptMs = 2500;

  /// Unison (r2/r3): seconds of "get ready" countdown (word shown) before the
  /// model plays, so the user is set to say it together.
  static const _unisonPrepSeconds = 5;

  /// Tick loudness for the soft beat heard UNDER the spoken word at the unison
  /// rungs (r2/r3) — quiet enough not to fight the model, loud enough to give the
  /// one-beat-per-syllable pulse. (No mic is open at r2/r3, so it can't bleed.)
  static const _kUnisonTickVolume = 0.35;

  /// WSOLA elongation for the user's **recorded** clip (pitch-preserving). The
  /// recording is already a human speaking deliberately, so it needs only modest
  /// stretching — say-it-together rungs most, r6 (solo) least. Tuned by feel.
  double _recordedStretch(Rung rung) {
    if (rung.isUnison) return 2.8; // r2/r3: say it together — slowest
    if (rung == Rung.r4 || rung == Rung.r5) return 2.2; // repeat-after
    return 1.8;
  }

  /// Slow-down basis for the **built-in (device TTS)** voice. Kept slower than
  /// the recorded path — the synthetic voice runs fast otherwise — so the user
  /// can still keep pace. (Larger value → slower TTS; see [GuidePlayer.play].)
  double _ttsStretch(Rung rung) {
    if (rung.isUnison) return 3.8;
    if (rung == Rung.r4 || rung == Rung.r5) return 3.0;
    return 2.4;
  }

  // The per-rung elongation, scaled by the caregiver's playback-speed setting:
  // a slower speed (0.5×) elongates more (≈2× the stretch). Guarded against 0.
  double get _speed => _playbackSpeed <= 0 ? 1.0 : _playbackSpeed;
  double _recordedStretchFor(Rung rung) => _recordedStretch(rung) / _speed;
  double _ttsStretchFor(Rung rung) => _ttsStretch(rung) / _speed;

  // One beat period (ms) at this word's current tempo — the warp target (one
  // syllable per beat) and the metronome's own period; they must match so the
  // warped audio rides the pulse.
  int _beatPeriodMsFor(int id) {
    final bpm = _progState[id]?.bpm ?? _baseBpm;
    return (60000 / bpm).round();
  }

  // Whether the recorded guide for [id] can be beat-warped (a real clip + at
  // least two confirmed nuclei to space across the beats).
  bool _canBeatWarp(int id) =>
      _guideClip[id] != null && (_guideNuclei[id]?.length ?? 0) >= 2;

  // Play the guide for [id], starting on the next beat so the warped
  // one-syllable-per-beat audio lines up with the metronome pulse. When the clip
  // can't be warped (no clip / too few nuclei) it falls back to the per-rung
  // uniform elongation, played immediately. [cutLast] drops the final syllable
  // (R3). NOTE: the beat-warped path is paced by the metronome tempo, so the
  // caregiver playback-speed only applies to the uniform/TTS fallback.
  void _playGuide(int id, Rung rung,
      {required void Function() onComplete, bool cutLast = false}) {
    final canWarp = _canBeatWarp(id);
    final beatMs = _beatPeriodMsFor(id);
    void doPlay() {
      _guide.play(
        clipPath: _guideClip[id],
        text: _phraseText[id] ?? '',
        stretch: _recordedStretchFor(rung),
        ttsStretch: _ttsStretchFor(rung),
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
      final remainMs =
          ((1 - engine.currentPhase) * beatMs).round().clamp(0, beatMs);
      _guideStartTimer =
          Timer(Duration(milliseconds: remainMs), () => mounted ? doPlay() : null);
    } else {
      doPlay();
    }
  }

  int _prepCountdown = 0; // >0 while the unison "get ready" countdown is showing
  Timer? _prepTimer;
  Timer? _r0Timer; // drives r0's tap windows
  Timer? _guideStartTimer; // delays guide playback to the next beat (beat-sync)
  // How r0 promoted, per phrase, for the block log: window1-pass / window2-forced.
  final Map<int, String> _r0Outcome = {};

  /// Reps a word runs this session: r0 is a single tap-window visit (it always
  /// promotes after at most two internal windows); every judged rung (r1–r6)
  /// runs a 3-rep caregiver-verdict block.
  int _repsForRung(Rung rung) =>
      rung == Rung.r0 ? 1 : MitProgression.repsPerBlock;

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
      _sessionRungCap = profile.sessionRungCap == null
          ? null
          : rungFromLevel(profile.sessionRungCap!);
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
      _baseBpm = profile.metronomeBpm;
      // The progression record per phrase — the single source of truth for the
      // rung this session. Rung seeds from the phrase row (caregiver-visible in
      // settings); tier comes from the progression_state record. The word's tempo
      // is its stored value but never faster than the caregiver's base tempo (so
      // a reduction-on-failure shows, while the default 60 maps to the base).
      _profileId = profile.profileId;
      _progState.clear();
      _blockLabels.clear();
      for (final ph in phrases) {
        final stored =
            await _repository.getProgressionState(profile.profileId, ph.phraseId);
        final seedBpm = math.min(stored.bpm, profile.metronomeBpm);
        _progState[ph.phraseId] = ProgressionState(
          profileId: profile.profileId,
          phraseId: ph.phraseId,
          rung: ph.rung, // authoritative rung is the phrase row (cleaned by v15)
          syllableTier: stored.syllableTier,
          bpm: seedBpm,
        );
        // Device-visible: the rung this session OPENS at, per word. If this ever
        // shows R6 for a word that shouldn't be there, the saved rung is wrong
        // (not the live logic) — the v15 migration resets legacy-inflated rungs.
        debugPrint('[PROGRESSION] init phrase=${ph.phraseId} "${ph.phraseText}" '
            'seedRung=${ph.rung.code} tier=${stored.syllableTier} bpm=$seedBpm');
      }
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

      // Each word runs as consecutive reps at its current rung (therapy addendum
      // §4); progression is decided after the block. Judged rungs (r1–r6) get a
      // 3-rep block; r0 gets a single tap-window visit (its two windows are
      // internal). So the session list repeats each phrase by its rung's reps.
      final controller = PracticeController(
        phraseIds: [
          for (final p in phrases)
            for (var i = 0; i < _repsForRung(_rungOf(p.phraseId)); i++)
              p.phraseId,
        ],
        // Generous safety cap: the screen normally drives the advance per rung
        // (below); this only fires if that never arrives. In demo mode we lift it
        // so nothing auto-advances — the R0 arena (which has no screen-driven
        // advance there) holds until the presenter picks another stage.
        guideBeats: _demoModeEnabled ? (1 << 30) : 12,
        rungOf: _rungOf,
        onEnterReferencePrompt: _onEnterReference,
        onEnterInputCapture: _onEnterCapture,
        // Capture ended (silence or beat timeout): stop the mic.
        onLeaveInputCapture: (_) => _mic.stop(),
        // Verdict state (every rung): restore the tick, stop any guide.
        onEnterSystemTransition: _onEnterCaregiver,
        // Persist each finished attempt to the local database (and try to sync).
        onAttemptComplete: (result) => _saveAttempt(result),
      );

      final engine = MetronomeEngine(
        vsync: this,
        bpm: profile.metronomeBpm,
        soundEnabled: profile.soundEnabled,
        visualEnabled: profile.visualEnabled,
        hapticEnabled: profile.hapticEnabled,
        onBeat: controller.onBeat, // the heartbeat that drives the FSM
      )..emphasizeBeat = true; // the session opens on "tap the beat" — emphasise it

      // Per-session ambient calibration (therapy §5): sample the room's noise
      // floor so silence-detection adapts to the environment. Runs here, before
      // the metronome/guide start, so nothing else is making sound. Best-effort —
      // on failure we keep the default threshold.
      try {
        final tmp = await getTemporaryDirectory();
        await _mic.calibrateAmbient(
            rawPath: p.join(tmp.path, 'ambient_cal.wav'));
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

      controller.start();
      engine.start();
    } catch (e) {
      setState(() => _error = 'Could not start practice: $e');
    }
  }

  // Reference_Prompt, shaped by the phrase's rung (therapy addendum §4). The
  // model always plays to completion (r3 fading) — the user produces along with
  // it for unison rungs — then we advance. Only the solo rungs (r4–r6) open the
  // mic afterward (the controller routes there); unison/hum/beat go to the
  // caregiver verdict, so the recorder never cuts off the model.
  /// The single source of truth for a phrase's current rung this session.
  /// Falls back to unison (R2) — the lowest appropriate rung — never a high one.
  Rung _rungOf(int id) => _progState[id]?.rung ?? Rung.r2;

  void _onEnterReference(int id) {
    // New prompt: invalidate any advance still pending from the previous one.
    _promptGen++;
    final rung = _rungOf(id);
    // Beat/hum rungs (r0/r1) ARE about the beat — keep the tick at full volume
    // and emphasise the haptic so the user can feel/follow it. Unison rungs
    // (r2/r3) keep a SOFT tick under the spoken word so the user hears one beat
    // per syllable (safe — no mic there). Repeat rungs (r4–r6) mute the tick: the
    // model is solo and the mic opens for capture, so a tick would bleed in.
    final beatPhase = rung == Rung.r0 || rung == Rung.r1;
    final unison = rung.isUnison; // r2/r3
    _engine?.tickVolume = beatPhase ? 1.0 : _kUnisonTickVolume;
    _engine?.soundEnabled = (beatPhase || unison) ? _soundPreference : false;
    _engine?.emphasizeBeat = beatPhase;
    // Fix 2: apply this word's tempo to the live metronome HERE — at the prompt
    // boundary, never mid-prompt. The controller now counts beats-since-entry, so
    // re-anchoring the scheduler can't trip a timeout. The guard means it only
    // re-anchors when the tempo actually differs (i.e. once per word).
    final wordBpm = _progState[id]?.bpm;
    if (wordBpm != null && _engine != null && _engine!.bpm != wordBpm) {
      _engine!.setBpm(wordBpm);
    }
    if (rung.isUnison) {
      // "Say it together": show the word, count down 3…2…1 so the user is ready,
      // then play the model for them to produce along with (no recording).
      _startUnisonPrep(id, rung);
    } else if (rung.playsModel) {
      // r4/r5: listen to the model (beat-warped), then a breath, then the mic.
      _playGuide(id, rung, onComplete: () => _advanceAfter(_afterModelMs(rung)));
    } else if (rung == Rung.r0) {
      // r0: a tap-along exposure window (two windows max, then promote). In demo
      // mode we DON'T run the windows — they finalize an attempt, evaluate a
      // block and move on; the presenter just wants to SHOW the R0 arena and
      // switch stages by hand with the demo bar.
      if (!_demoModeEnabled) _startR0Windows(id);
    } else {
      // No model plays here: r1 hum window (then verdict), r6 brief get-ready
      // (then the mic). Both end via the controller's rung routing.
      _advanceAfter(rung == Rung.r1 ? _humMs : _soloPromptMs);
    }
  }

  // r0: a tap-along exposure window. Give one window; if the tap-sync threshold
  // is met within it, promote now; otherwise give a SECOND equal window and then
  // promote regardless. Tap performance ONLY decides whether the second window is
  // offered — r0 always ends in promotion (the no-trap floor). No verdict.
  void _startR0Windows(int id) {
    _r0Timer?.cancel();
    debugPrint('[PROGRESSION] R0 phrase=$id "${_phraseText[id]}" window1 start '
        '(${_r0TapWindowMs}ms, threshold $_r0TapSyncThreshold)');
    _r0Timer = Timer(const Duration(milliseconds: _r0TapWindowMs), () {
      final score = _controller?.currentSyncScore;
      if (score != null && score >= _r0TapSyncThreshold) {
        _r0Outcome[id] = 'window1-pass(${score.toStringAsFixed(2)})';
        debugPrint('[PROGRESSION] R0 phrase=$id window1 PASSED '
            'score=${score.toStringAsFixed(2)} → promote');
        if (mounted) _controller?.endReferencePrompt();
      } else {
        debugPrint('[PROGRESSION] R0 phrase=$id window1 missed '
            'score=${score?.toStringAsFixed(2) ?? "none"} → offering window2');
        _r0Timer = Timer(const Duration(milliseconds: _r0TapWindowMs), () {
          _r0Outcome[id] = 'window2-forced';
          debugPrint('[PROGRESSION] R0 phrase=$id force-promote after window2');
          if (mounted) _controller?.endReferencePrompt();
        });
      }
    });
  }

  // Unison prep countdown, then play the model and advance to the verdict.
  void _startUnisonPrep(int id, Rung rung) {
    _prepTimer?.cancel();
    setState(() => _prepCountdown = _unisonPrepSeconds);
    _prepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_prepCountdown <= 1) {
        t.cancel();
        setState(() => _prepCountdown = 0);
        // Say-it-together (beat-warped, soft tick under it). R3 ("model fades")
        // drops the final syllable — the guide player places the cut on the
        // warped timeline from the confirmed nuclei — so the user ends it alone.
        _playGuide(id, rung,
            cutLast: rung == Rung.r3,
            onComplete: () => _advanceAfter(_unisonTailMs));
      } else {
        setState(() => _prepCountdown -= 1);
      }
    });
  }

  int _afterModelMs(Rung rung) => switch (rung) {
        Rung.r5 => _delayedRepeatMs, // delayed repeat
        Rung.r4 => _repeatBreathMs, // repeat after
        _ => _unisonTailMs, // r2/r3 unison: brief pause then verdict
      };

  // Open the mic. Only reached for r4–r6, and the guide has already finished, so
  // there's no playback to contend with.
  void _onEnterCapture(int id) {
    _guideStartTimer?.cancel();
    _guide.stop();
    _engine?.soundEnabled = false;
    _engine?.emphasizeBeat = false;
    _startCapture();
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

  // Save a finished attempt, then opportunistically push to the cloud. Runs in
  // the background (the controller calls this as the session continues).
  Future<void> _saveAttempt(AttemptResult result) async {
    // Demo mode is strictly ephemeral: a live demonstration must never alter real
    // therapy history, so nothing is persisted — no attempt row, no progression
    // block (no rung change), no daily rollup, no sync.
    if (_demoModeEnabled) return;
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final rung = _rungOf(result.phraseId);
    try {
      final attemptId = await _repository.insertAttempt(
        sessionId: sessionId,
        phraseId: result.phraseId,
        evaluationLabel: result.evaluationLabel,
        tappingSynchronizationScore: result.syncScore,
        latencyMs: result.latencyMs,
        durationMs: result.durationMs,
        localEncryptedAudioPath: result.localEncryptedAudioPath,
        rungAtAttempt: rung.level, // Phase 3: which rung this was produced at
        tierAtAttempt:
            _progState[result.phraseId]?.syllableTier, // and which syllable tier
      );
      // Phase 2B: score the clip against the phrase's recorded guide (similarity
      // + anchor) — only for rungs that yield a clean solo production (r4–r6).
      // Unison (r2/r3) is contaminated by the model; r0/r1 aren't the word.
      if (rung.cleanCapture) {
        await _scoring.scoreAttempt(
          attemptId: attemptId,
          phraseId: result.phraseId,
          profileId: _profileId ?? '',
          encryptedAttemptPath: result.localEncryptedAudioPath,
          guideClipPath: _guideClip[result.phraseId],
          evaluationLabel: result.evaluationLabel,
        );
      }
      // Phase 3 (MIT controller): progression is decided per BLOCK, not per
      // attempt — collect this rep's label and evaluate once the block is full.
      // The block size is the rung's reps (r0 = 1 window; r1–r6 = 3-rep block).
      if (_autoProgressEnabled) {
        final labels = _blockLabels.putIfAbsent(result.phraseId, () => []);
        labels.add(result.evaluationLabel);
        if (labels.length >= _repsForRung(rung)) {
          await _evaluateBlock(result.phraseId, labels);
          _blockLabels.remove(result.phraseId);
        }
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

  // Fold a finished 3-rep block through the MIT controller: the fast loop moves
  // the rung (advance / tempo-down / back-up / park), then the slow loop raises
  // the syllable tier if the word has earned it (≥90% over the recent sessions).
  // Persists the new rung (phrase row + progression record) for next session.
  Future<void> _evaluateBlock(int phraseId, List<int> labels) async {
    final profileId = _profileId ?? '';
    final before = _progState[phraseId] ??
        ProgressionState(
            profileId: profileId, phraseId: phraseId, rung: _rungOf(phraseId));

    // The caregiver comfort cap (low-energy days) limits how high a block may
    // advance the rung. It never demotes — the pass-never-demotes guard below
    // protects a phrase already above the cap.
    final result = _mit.evaluateBlock(before, labels, rungCap: _sessionRungCap);
    var after = result.state;
    // Slow loop (MIT tier gate): top-rung (R6 solo) mastery only, and only WITHIN
    // the current tier — the word's pass rate at R6 at this tier across the recent
    // sessions. Only fires while the word is actually at R6 (so a back-up after a
    // strong run can't trip it). Read it first so we can log why a tier did/didn't
    // advance. Raising the tier resets the rung to unison.
    final history = await _repository.sessionPassRates(profileId,
        phraseId: phraseId,
        minRung: Rung.r6.level,
        tier: before.syllableTier);
    final willRaiseTier =
        before.rung == Rung.r6 && _mit.shouldRaiseTier(history);
    debugPrint('[PROGRESSION] tier-gate phrase=$phraseId "${_phraseText[phraseId]}" '
        'tier=${before.syllableTier} atTopRung=${before.rung == Rung.r6} '
        'topRungPassRates=${history.map((r) => r.toStringAsFixed(2)).toList()} '
        'sessions=${history.length} '
        'need ${_mit.tierWindow}@≥${_mit.tierPassRate} → raiseTier=$willRaiseTier');
    if (willRaiseTier) {
      after = _mit.raiseTier(after);
    }
    // Hard invariant: a pass-majority block can never lower the rung (a tier
    // raise to unison is exempt). Belt-and-suspenders over the fast loop.
    after = _mit.guardPassNeverDemotes(before, after, labels);

    // Device-visible: the exact transition and the verdict tally that drove it,
    // so any wrong move (e.g. a Pass block lowering the rung) is plain in logcat.
    // For r0, also note which window promoted (or whether it was force-promoted).
    final passes = labels.where((l) => l == 1).length;
    final fails = labels.where((l) => l == 0).length;
    final unsure = labels.where((l) => l == 2).length;
    final r0note =
        before.rung == Rung.r0 ? ' r0=${_r0Outcome[phraseId] ?? "?"}' : '';
    final capNote =
        _sessionRungCap == null ? '' : ' cap=${_sessionRungCap!.code}';
    debugPrint('[PROGRESSION] block phrase=$phraseId "${_phraseText[phraseId]}" '
        'labels=$labels (P=$passes F=$fails U=$unsure)$r0note$capNote '
        'rung ${before.rung.code}→${after.rung.code} '
        'tier ${before.syllableTier}→${after.syllableTier} '
        'bpm ${before.bpm}→${after.bpm} outcome=${result.outcome.name}');
    _r0Outcome.remove(phraseId);

    // Update the single in-memory source of truth, then persist: the rung to the
    // phrase row (caregiver-visible) and the tier/tempo to the progression record.
    _progState[phraseId] = after;
    if (after.rung != before.rung) {
      await _repository.setRung(phraseId, after.rung);
    }
    await _repository.upsertProgressionState(after);

    // Announce — a level change takes priority; otherwise a tempo ease is shown
    // as supportive help (never as failure).
    if (after.rung != before.rung || after.syllableTier != before.syllableTier) {
      _showProgressChange(phraseId, before, after);
    } else if (result.outcome == RungOutcome.slowedTempo) {
      _showTempoEased(phraseId, after.bpm);
    }
  }

  // Fix 2: a calm, non-punitive cue that the beat is being slowed to help — never
  // framed as failure. (The slower beat applies the next time the word comes up.)
  void _showTempoEased(int phraseId, int bpm) {
    if (!mounted) return;
    final word = _phraseText[phraseId] ?? 'that word';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF3F6E8C), // calm slate-blue, not a warning
        content: Row(
          children: [
            const Icon(Icons.slow_motion_video, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text('Slowing the beat for “$word” to make it easier',
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ],
        ),
      ));
  }

  // Briefly tell the caregiver how a word's level changed after its block. Names
  // the word, because by the time this shows the screen has already moved on to
  // the NEXT word — so an unnamed "moved up to R4" would look like it's about
  // whatever is on screen. Takes effect the next time this word appears.
  void _showProgressChange(int phraseId, ProgressionState before, ProgressionState after) {
    if (!mounted) return;
    final word = _phraseText[phraseId] ?? 'that word';
    final tierUp = after.syllableTier > before.syllableTier;
    final up = after.rung.level > before.rung.level;
    // The change applies the NEXT time this word comes up — the screen has
    // already moved to the next word — so every message names the word and says
    // "next time", so it's never read as the rung of whatever is on screen now.
    final (color, icon, text) = tierUp
        ? (
            const Color(0xFF2E7D5B),
            Icons.workspace_premium,
            '“$word”: new level — next time starts at ${after.rung.code} · ${after.rung.title}'
          )
        : up
            ? (
                const Color(0xFF2E7D5B),
                Icons.arrow_upward,
                '“$word”: next time moves up to ${after.rung.code} · ${after.rung.title}'
              )
            : (
                const Color(0xFF8A6D1F),
                Icons.arrow_downward,
                '“$word”: next time eases to ${after.rung.code} · ${after.rung.title}'
              );
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        backgroundColor: color,
        content: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
                child: Text(text,
                    style: const TextStyle(color: Colors.white, fontSize: 16))),
          ],
        ),
      ));
  }

  // --- Demo mode (presenter level picker) ----------------------------------
  // Jump the CURRENT word to [rung] for a live demonstration, then re-run the
  // word so the new rung's behaviour (model playback, cues, stage tint) plays
  // out at once. This changes only the in-session rung — it is NOT persisted to
  // the phrase row or progression record, so a demo never disturbs real history.
  void _setDemoRung(Rung rung) {
    final controller = _controller;
    if (controller == null) return;
    final id = controller.currentPhraseId;
    if (_rungOf(id) == rung) return; // already there — nothing to do
    // Cancel everything in flight from the prompt we're interrupting.
    _prepTimer?.cancel();
    _r0Timer?.cancel();
    _guideStartTimer?.cancel();
    _guide.stop();
    _mic.stop();
    _r0Outcome.remove(id);
    // In-session source of truth only (no setRung / upsertProgressionState).
    final before = _progState[id] ??
        ProgressionState(
            profileId: _profileId ?? '', phraseId: id, rung: rung);
    _progState[id] = before.copyWith(rung: rung);
    // A demo jump shouldn't feed the auto-progression block tally either.
    _blockLabels.remove(id);
    setState(() => _prepCountdown = 0);
    debugPrint('[DEMO] jump phrase=$id "${_phraseText[id]}" '
        '${before.rung.code}→${rung.code}');
    // Re-run the word from the top of its prompt at the new rung.
    controller.restartCurrentWord();
  }

  // The presenter's level picker: a compact R0–R6 row pinned bottom-centre, only
  // shown when demo mode is enabled in settings. The current rung is highlighted.
  Widget _demoBar(PracticeController controller) {
    final current = controller.currentRung;
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
            const Padding(
              padding: EdgeInsets.only(left: 4, right: 10),
              child: Text('DEMO',
                  style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5)),
            ),
            for (final r in Rung.values)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _demoRungButton(r, selected: r == current),
              ),
          ],
        ),
      ),
    );
  }

  Widget _demoRungButton(Rung rung, {required bool selected}) {
    return Material(
      color: selected ? Colors.white : Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: selected ? null : () => _setDemoRung(rung),
        child: Tooltip(
          message: rung.title,
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            child: Text(
              rung.code,
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
    _r0Timer?.cancel();
    _guideStartTimer?.cancel();
    _engine?.dispose();
    _controller?.dispose();
    _guide.dispose();
    _mic.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Practice')),
        body: Center(
          child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
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
            repsPerBlock: MitProgression.repsPerBlock,
            // Caregiver escape hatch from the element-free R0/R1 tap sandbox
            // (the right-edge verdict dock is hidden there).
            onCaregiverUnlock: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsPortal(repository: _repository),
              ),
            ),
          ),
          // "Get ready" countdown for unison rungs — a banner at the bottom so it
          // never covers the word the user is reading in the centre.
          if (_prepCountdown > 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 28,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Get ready to say it together   ',
                          style: TextStyle(fontSize: 18, color: Colors.white)),
                      Text('$_prepCountdown',
                          style: const TextStyle(
                              fontSize: 44,
                              fontWeight: FontWeight.bold,
                              color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ),
          // Presenter level picker (demo mode only). Padded clear of the right-
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
