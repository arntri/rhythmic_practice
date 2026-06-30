import 'package:flutter/foundation.dart';

import 'progression.dart';
import 'tap_sync.dart';

/// The finalized result of one phrase attempt, handed to [PracticeController.
/// onAttemptComplete] so the screen can persist it. Mirrors the columns of
/// `exercise_attempts` that we can fill in at State_4.
class AttemptResult {
  final int phraseId;
  final double? syncScore;
  final int evaluationLabel;
  final int? latencyMs;
  final int? durationMs;
  final String? localEncryptedAudioPath;

  const AttemptResult({
    required this.phraseId,
    required this.syncScore,
    required this.evaluationLabel,
    required this.latencyMs,
    required this.durationMs,
    this.localEncryptedAudioPath,
  });
}

/// The four states of the practice loop (brief §3), plus a terminal state for
/// when the session's phrase limit is reached.
enum PracticeState {
  /// State_1: metronome runs; user taps in time to lock into the beat.
  preparation,

  /// State_2: the audio guide intones the phrase on the beat; phrase shown.
  referencePrompt,

  /// State_3: mic is open; user says the phrase along to the beat.
  inputCapture,

  /// State_4: save the attempt, wait for the caregiver's Pass/Fail/Unsure.
  systemTransition,

  /// All phrases for this session are done.
  sessionComplete,
}

/// Drives one practice session through the practice states. State_1
/// (Preparation / beat-lock) runs ONCE at the start of a session; after that
/// each phrase flows State_2 → State_4 and the next phrase begins straight at
/// State_2, so the user locks into the beat once rather than before every word.
///
/// IMPORTANT design choice: this controller is **beat-driven**, not clock-
/// driven. The metronome calls [onBeat] every beat, and timed transitions
/// (how long the guide plays, how long the mic stays open) are counted in
/// *beats*. That keeps the whole machine deterministic and unit-testable — a
/// test just calls [onBeat]/[registerTap]/[setEvaluation] by hand, with no
/// real time, audio, or microphone involved.
///
/// The guide (Step 4) and mic (Step 5) are not implemented here yet. Instead we
/// expose callback "seams" that fire when those states begin/end, and advance
/// after a placeholder number of beats. Later steps replace the placeholders
/// with the real guide/mic without changing this state machine.
class PracticeController extends ChangeNotifier {
  PracticeController({
    required List<int> phraseIds,
    this.tapsToAdvance = 3,
    this.lockTolerance = 0.25,
    this.guideBeats = 4,
    this.captureBeats = 6,
    Rung Function(int phraseId)? rungOf,
    this.onEnterReferencePrompt,
    this.onEnterInputCapture,
    this.onLeaveInputCapture,
    this.onEnterSystemTransition,
    this.onAttemptComplete,
  })  : assert(phraseIds.isNotEmpty),
        _phraseIds = phraseIds,
        // Default to R4 (listen-then-repeat) so callers that don't pass rungs
        // get the classic play-model-then-capture flow.
        _rungOf = rungOf ?? ((_) => Rung.r4);

  final List<int> _phraseIds;

  /// The progression rung for a phrase (therapy addendum §4). Drives whether
  /// capture happens (R0 has none) — the screen handles the audio specifics.
  final Rung Function(int phraseId) _rungOf;

  /// The rung of the phrase currently being practiced.
  Rung get currentRung => _rungOf(currentPhraseId);

  /// How many in-time taps end State_1 (Preparation). Kept deliberately small:
  /// for the target user the warm-up should be easy, not a skill gate.
  final int tapsToAdvance;

  /// How close to the beat a tap must be to count toward the lock, as a fraction
  /// of one beat interval (0.25 ≈ within a quarter-beat, ~250 ms at 60 BPM). Wider
  /// than the scoring sense of "in time" so locking in stays forgiving.
  final double lockTolerance;

  /// PLACEHOLDER: beats the guide "plays" before State_2 → State_3.
  /// Real guide length arrives in Step 4.
  final int guideBeats;

  /// PLACEHOLDER: beats the mic stays "open" before State_3 → State_4.
  /// Real silence-based close arrives in Step 5.
  final int captureBeats;

  // Seams for later steps. Each receives the current phrase id.
  final void Function(int phraseId)? onEnterReferencePrompt;
  final void Function(int phraseId)? onEnterInputCapture;
  final void Function(int phraseId)? onLeaveInputCapture;

  /// Fired when the caregiver-verdict state begins — used to restore the tick
  /// and stop any guide/mic, for every rung (capturing or not).
  final void Function()? onEnterSystemTransition;

  /// Fired once per phrase, when the caregiver's verdict finalizes the attempt.
  /// The screen uses this to save the attempt to the database.
  final void Function(AttemptResult result)? onAttemptComplete;

  PracticeState _state = PracticeState.preparation;
  PracticeState get state => _state;

  int _index = 0;
  int get currentIndex => _index;
  int get phraseCount => _phraseIds.length;
  int get currentPhraseId => _phraseIds[_index];

  /// Word position/count by CONSECUTIVE-group, so the "Word x of y" counter is
  /// right even when words have different rep counts (R0 runs a single window;
  /// R1–R6 run a 3-rep block). Each word's reps sit together in [_phraseIds], so
  /// a change in id marks a new word.
  int get currentWordIndex {
    var w = 0;
    for (var i = 1; i <= _index && i < _phraseIds.length; i++) {
      if (_phraseIds[i] != _phraseIds[i - 1]) w++;
    }
    return w;
  }

  int get wordCount {
    if (_phraseIds.isEmpty) return 0;
    var c = 1;
    for (var i = 1; i < _phraseIds.length; i++) {
      if (_phraseIds[i] != _phraseIds[i - 1]) c++;
    }
    return c;
  }

  // Beats counted SINCE the current state began. A counter (incremented once per
  // beat) rather than an index delta, so a tempo change — which re-anchors the
  // metronome's beat index — can never make this jump and falsely trip a
  // beat-based timeout. (The screen drives the real advance; these are safety
  // fallbacks.)
  int _beatsInState = 0;

  int _inTimeTaps = 0;
  int get inTimeTaps => _inTimeTaps;

  final List<double> _tapPhases = [];

  int? _evaluationLabel;
  int? get evaluationLabel => _evaluationLabel;

  // Filled in by the microphone in Step 5.
  int? _latencyMs;
  int? _durationMs;
  String? _audioPath;

  /// Step 5 hook: the mic reports how long after the guide the user started
  /// speaking ([latencyMs]), how long they spoke ([durationMs]), and where the
  /// encrypted clip was saved ([audioPath], null if nothing was kept).
  void recordCaptureMetrics({int? latencyMs, int? durationMs, String? audioPath}) {
    _latencyMs = latencyMs;
    _durationMs = durationMs;
    _audioPath = audioPath;
  }

  /// 0..1 sync score for the current phrase so far (null if no taps yet).
  double? get currentSyncScore => syncScoreFromPhases(_tapPhases);

  /// Begin the session at the first phrase, in Preparation.
  void start() {
    _index = 0;
    _resetPhrase();
    _state = PracticeState.preparation;
    _beatsInState = 0;
    notifyListeners();
  }

  /// Called by the metronome on every beat. [beatIndex] is informational — state
  /// timeouts count beats since entry, not absolute indices, so they survive a
  /// tempo change.
  void onBeat(int beatIndex) {
    _beatsInState++;

    switch (_state) {
      case PracticeState.referencePrompt:
        if (_beatsInState >= guideBeats) {
          _leaveReferencePrompt();
        }
      case PracticeState.inputCapture:
        if (_beatsInState >= captureBeats) {
          onLeaveInputCapture?.call(currentPhraseId);
          _enter(PracticeState.systemTransition);
        }
      // Preparation advances on taps; systemTransition on the caregiver;
      // sessionComplete is terminal — none are beat-driven.
      case PracticeState.preparation:
      case PracticeState.systemTransition:
      case PracticeState.sessionComplete:
        break;
    }
  }

  /// Step 4: called when the audio guide finishes playing, to open capture as
  /// soon as the whole word has been heard (rather than after a fixed number of
  /// beats). No-op unless we're in Reference_Prompt. The beat-based [guideBeats]
  /// timeout in [onBeat] remains as a safety fallback if completion never fires.
  void endReferencePrompt() {
    if (_state != PracticeState.referencePrompt) return;
    _leaveReferencePrompt();
  }

  // Leave Reference_Prompt for the right next state given the rung: r4–r6 open
  // the mic; r1–r3 go to the caregiver verdict (no mic); r0 auto-completes.
  void _leaveReferencePrompt() {
    // r4–r6 produce a clean solo → open the mic (recorded + scored); the
    // caregiver verdict follows capture.
    if (currentRung.cleanCapture) {
      _enter(PracticeState.inputCapture);
      return;
    }
    // r1–r3 are judged but NOT recorded (the model/hum makes the mic useless):
    // r1 participation, r2 unison, r3 carried-the-fade → straight to the verdict.
    if (currentRung.isJudged) {
      _enter(PracticeState.systemTransition);
      return;
    }
    // r0 is the only un-judged rung: a tap-along exposure window that advances on
    // EXPOSURE, not performance. It auto-completes with a neutral label so poor
    // (or absent) taps can never produce a Fail that blocks progress — the screen
    // runs r0's two tap windows and always promotes (a user with hand weakness
    // must never be trapped below speech). The r0 tap-sync score is still captured
    // on the AttemptResult for analytics; it never gates advancement.
    _finishAttempt(_neutral);
  }

  /// Neutral label recorded for the un-judged r0 exposure rung: it counts toward
  /// neither Pass nor Fail in progression or stats.
  static const _neutral = 2; // Unsure

  /// Step 5: called by the microphone when it auto-closes on ~4.5 s of silence,
  /// to end capture *before* the beat-based safety timeout in [onBeat]. No-op
  /// unless we're currently capturing, so a late callback can't double-fire.
  void endCapture() {
    if (_state != PracticeState.inputCapture) return;
    onLeaveInputCapture?.call(currentPhraseId);
    _enter(PracticeState.systemTransition);
  }

  /// Called when the user taps the screen. [phase] is the metronome phase at the
  /// moment of the tap (0.0 = on the beat). Taps are collected for the sync
  /// score; in Preparation, enough in-time taps advance to State_2.
  void registerTap(double phase) {
    if (_state == PracticeState.sessionComplete) return;
    _tapPhases.add(phase);

    if (_state == PracticeState.preparation &&
        isInTime(phase, tolerance: lockTolerance)) {
      _inTimeTaps++;
      if (_inTimeTaps >= tapsToAdvance) {
        _enter(PracticeState.referencePrompt);
        return;
      }
    }
    notifyListeners();
  }

  /// Demo only: re-run the CURRENT word from the top of its reference prompt,
  /// without advancing to the next phrase or recording an attempt. The screen
  /// calls this after a presenter changes the current word's rung from the
  /// in-session level picker, so the new rung's behaviour (model playback, cues,
  /// stage tint) plays out immediately. Safe from any non-terminal state — it
  /// just resets the per-phrase scratch and re-enters Reference_Prompt.
  void restartCurrentWord() {
    if (_state == PracticeState.sessionComplete) return;
    _resetPhrase();
    _enter(PracticeState.referencePrompt);
  }

  /// The caregiver's verdict in State_4: 0 = Fail, 1 = Pass, 2 = Unsure.
  /// Records it, then advances to the next phrase or ends the session.
  void setEvaluation(int label) {
    if (_state != PracticeState.systemTransition) return;
    _finishAttempt(label);
  }

  // Finalize the current attempt with [label] (caregiver or app), hand it to the
  // screen to save, then advance to the next phrase or end the session.
  void _finishAttempt(int label) {
    _evaluationLabel = label;

    // Hand the finalized attempt to the screen for saving, BEFORE we reset.
    onAttemptComplete?.call(AttemptResult(
      phraseId: currentPhraseId,
      syncScore: currentSyncScore,
      evaluationLabel: label,
      latencyMs: _latencyMs,
      durationMs: _durationMs,
      localEncryptedAudioPath: _audioPath,
    ));

    if (_index + 1 < _phraseIds.length) {
      _index++;
      _resetPhrase();
      // "Lock once, then flow": the beat lock happens only at the start of a
      // session (State_1). Subsequent phrases skip Preparation and go straight
      // to the guide, so the user isn't re-tapping a timing gate before every
      // word. (Taps during the phrase are still collected for the sync score.)
      _enter(PracticeState.referencePrompt);
    } else {
      _enter(PracticeState.sessionComplete);
    }
  }

  // Enter a new state: reset the beats-in-state counter, run its seam, notify.
  void _enter(PracticeState next) {
    _state = next;
    _beatsInState = 0;
    switch (next) {
      case PracticeState.referencePrompt:
        onEnterReferencePrompt?.call(currentPhraseId);
      case PracticeState.inputCapture:
        onEnterInputCapture?.call(currentPhraseId);
      case PracticeState.systemTransition:
        onEnterSystemTransition?.call();
      default:
        break;
    }
    notifyListeners();
  }

  void _resetPhrase() {
    _inTimeTaps = 0;
    _tapPhases.clear();
    _evaluationLabel = null;
    _latencyMs = null;
    _durationMs = null;
    _audioPath = null;
  }
}
