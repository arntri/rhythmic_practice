import 'package:flutter/foundation.dart';

import 'mit_sequence.dart';
import 'tap_sync.dart';

/// One raw tap in the per-tap stream (ML logging audit item 16a): the monotonic
/// touch-down time ([downMs], ms since the session's controller started), the
/// metronome [phase] at touch-down (0..1), and the press [dwellMs]
/// (touch-down→up) — null until (or unless) the release is observed.
///
/// This is the un-aggregated data the fatigue detector needs: the attempt's lone
/// [AttemptResult.syncScore] averages the phases away, so dwell and inter-tap-
/// interval variance can't be recovered from it. Persisted per tap to
/// `tap_events`.
class TapEvent {
  TapEvent({required this.downMs, required this.phase, this.dwellMs});

  final int downMs;
  final double phase;

  /// Press duration (ms). Mutable so the release handler can fill it in on the
  /// matching pointer-up; stays null if the finger-up is never seen.
  int? dwellMs;
}

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

  /// The MIT step this production was made at. Carried on the result rather than
  /// looked up afterwards: by the time the screen saves the attempt the run may
  /// already have advanced or backed up, so the step has to travel *with* the
  /// production it describes.
  final MitStep step;

  /// Which production of that step this was (1-based, 1–3 — see [RepRule]).
  final int repNumber;

  /// The raw per-tap stream captured during this attempt (item 16a). Empty when
  /// no taps were made. The screen persists these to `tap_events`.
  final List<TapEvent> taps;

  const AttemptResult({
    required this.phraseId,
    required this.syncScore,
    required this.evaluationLabel,
    required this.latencyMs,
    required this.durationMs,
    required this.step,
    this.repNumber = 1,
    this.localEncryptedAudioPath,
    this.taps = const [],
  });
}

/// The four states of the practice loop (brief §3), plus a terminal state for
/// when the session's phrase limit is reached.
enum PracticeState {
  /// State_1a: session warm-up, part 1 — metronome runs; user taps in time to
  /// lock into the beat. Readiness only; NOT tied to any word (tapping can never
  /// advance a word). Runs once at session start.
  preparation,

  /// State_1b: session warm-up, part 2 — hum along to the beat for a few beats,
  /// then flow into the first word. Also once-per-session; general vocal warm-up,
  /// not a per-word rung.
  warmUpHum,

  /// State_1c: the PER-ITEM hum — MIT's step 1, and the one step in the sequence
  /// that is never judged. The item's melody (two pitches, one syllable per beat,
  /// no words) is hummed twice while the caregiver taps; the word is withheld
  /// from the screen. It is how the melody is handed over, before there is
  /// anything to retrieve.
  ///
  /// Distinct from [warmUpHum], which is a once-per-session vocal warm-up with
  /// no phrase attached.
  phraseHum,

  /// State_2: the prompt for a judged step — the model intoning the phrase on
  /// the beat (or, at the probe step, the question), with the phrase shown.
  referencePrompt,

  /// State_3: mic is open; user says the phrase along to the beat.
  inputCapture,

  /// State_4: save the attempt, wait for the caregiver's Pass/Fail/Unsure.
  systemTransition,

  /// A step did not land, so the patient is dropping to the previous one — a
  /// brief held moment before that easier step re-runs.
  ///
  /// A state rather than a passing toast, because it is the one transition in
  /// the app most likely to be read as demotion. It needs a screen that says
  /// what is happening, in the patient's field, before the earlier step starts.
  backingUp,

  /// Two step failures in a row: this item is done for today and the session is
  /// about to move to the next one. Named on screen and then left behind — the
  /// old app spliced in an easier word here to engineer a win, and with that
  /// gone the reassurance has to live in this moment instead.
  itemSetAside,

  /// The caregiver has opened their panel. The session stops on the spot — the
  /// beat included — because nothing should be running while someone reads notes
  /// about the person sitting in front of the screen. The rotation into portrait
  /// IS the privacy boundary, and this is its other half.
  ///
  /// Coming back does **not** resume mid-word: the current step restarts from
  /// its beginning, and it waits for a tap rather than starting itself.
  paused,

  /// Between items: the app is offering a break. MIT is intensive — the research
  /// protocols run to an hour and a half — and a tiring person produces worse
  /// and learns less, so the offer is made *for* them rather than waiting for a
  /// caregiver to think of it.
  ///
  /// A state rather than an overlay, because the session genuinely stops here:
  /// the beat stops, nothing advances, and it resumes only when someone says so
  /// ([resumeFromRest]) or ends the session ([finishSessionEarly]).
  rest,

  /// All phrases for this session are done.
  sessionComplete,
}

/// Drives one practice session through the practice states. State_1
/// (Preparation / beat-lock) runs ONCE at the start of a session; after that
/// each item flows State_2 → State_4 and the next item begins straight at
/// State_2, so the user locks into the beat once rather than before every word.
///
/// **The session's shape is MIT's, not a ladder's.** Every item runs the whole
/// step sequence for the patient's [level] in one sitting ([MitItemRun]), a
/// failed step backs up to the previous one immediately, and two failures in a
/// row set the item aside. There is no per-word rung to occupy and nothing to
/// carry between sessions but the person's level — which is the correction this
/// controller exists to embody.
///
/// IMPORTANT design choice: this controller is **beat-driven**, not clock-
/// driven. The metronome calls [onBeat] every beat, and timed transitions
/// (how long the guide plays, how long the mic stays open) are counted in
/// *beats*. That keeps the whole machine deterministic and unit-testable — a
/// test just calls [onBeat]/[registerTap]/[setEvaluation] by hand, with no
/// real time, audio, or microphone involved.
///
/// The audio and the microphone live in the SCREEN, not here. This exposes
/// callback "seams" that fire when each state begins and ends; the screen plays
/// the guide, opens the mic, and calls back when they finish. The beat counts
/// below are safety fallbacks for a completion callback that never arrives —
/// they are not how the session is normally paced.
class PracticeController extends ChangeNotifier {
  PracticeController({
    required List<int> phraseIds,
    this.tapsToAdvance = 3,
    this.lockTolerance = 0.25,
    this.guideBeats = 4,
    this.captureBeats = 6,
    this.warmUpBeats = 8,
    this.phraseHumBeats = 12,
    this.messageBeats = 3,
    this.level = MitLevel.two,
    this.onEnterReferencePrompt,
    this.onEnterWarmUpHum,
    this.onEnterPhraseHum,
    this.onEnterInputCapture,
    this.onLeaveInputCapture,
    this.onEnterSystemTransition,
    this.onEnterRest,
    this.onEnterPaused,
    this.onAttemptComplete,
    this.onStepBackedUp,
    this.onItemSetAside,
  }) : assert(phraseIds.isNotEmpty),
       _phraseIds = List<int>.unmodifiable(phraseIds);

  /// The session's items — **one entry per item, never repeated**. Reps are no
  /// longer a property of the list: each item runs its level's whole step
  /// sequence in one sitting, and how many productions that takes is decided
  /// step by step by [RepRule]. (Under the old block model the same id appeared
  /// three times here, which is why the "word x of y" counter had to group
  /// consecutive duplicates.)
  final List<int> _phraseIds;

  /// The **patient's** MIT level, fixed for the session. It selects the step
  /// sequence every item runs; it is not a property of any one word.
  final MitLevel level;

  /// The current item's walk through [level]'s step sequence — the object that
  /// holds MIT's back-up and set-aside rules. Replaced when the session moves to
  /// the next item.
  MitItemRun _run = MitItemRun(level: MitLevel.two);
  MitItemRun get run => _run;

  /// The MIT step being worked on right now.
  MitStep get currentStep => _run.currentStep;

  /// Which production of [currentStep] is next (1-based, 1–3).
  int get repNumber => _run.repNumber;

  /// Verdicts given so far at [currentStep].
  List<Verdict> get currentStepVerdicts => _run.currentStepVerdicts;

  /// How the current item's run has ended, or [ItemOutcome.running].
  ItemOutcome get itemOutcome => _run.outcome;

  /// What the most recent verdict decided — another production of the same step,
  /// a pass onto the next, or a failure that backed up. Null until the first
  /// verdict of the session. The screen reads this to shape the moment it is
  /// showing; [onStepBackedUp] and [onItemSetAside] are the pushed equivalents.
  RepDecision? get lastDecision => _lastDecision;
  RepDecision? _lastDecision;

  /// How many in-time taps end State_1 (Preparation). Kept deliberately small:
  /// for the target user the warm-up should be easy, not a skill gate.
  final int tapsToAdvance;

  /// How close to the beat a tap must be to count toward the lock, as a fraction
  /// of one beat interval (0.25 ≈ within a quarter-beat, ~250 ms at 60 BPM). Wider
  /// than the scoring sense of "in time" so locking in stays forgiving.
  final double lockTolerance;

  /// SAFETY FALLBACK: beats a prompt may run before the controller moves on by
  /// itself. The screen normally drives the advance when the audio finishes;
  /// this only fires if that never arrives.
  final int guideBeats;

  /// SAFETY FALLBACK: beats the mic may stay open before the controller closes
  /// it. The mic normally closes itself on silence ([endCapture]).
  final int captureBeats;

  /// Beats the warm-up hum runs before flowing into the first word (State_1b →
  /// State_2). Once per session.
  final int warmUpBeats;

  /// SAFETY fallback: beats the hum step (State_1c) may run before the flow
  /// moves on regardless. The screen ends the hum precisely, when the synthesized
  /// melody finishes ([endPhraseHum]); this only catches a hum whose completion
  /// never arrives. Set to 0 to skip the hum step entirely — which unit tests do,
  /// and which is also the escape hatch if the step ever needs disabling.
  final int phraseHumBeats;

  /// Whether the hum step runs at all.
  bool get phraseHumEnabled => phraseHumBeats > 0;

  /// Beats the backing-up and set-aside moments hold before the session carries
  /// on. Long enough to be read, short enough not to become a wait. 0 skips them
  /// entirely, which is what unit tests do unless they are testing them.
  final int messageBeats;

  /// The item the session moves to after this one, for the set-aside screen's
  /// "next up" line. Null on the last item.
  int? get nextPhraseId =>
      _index + 1 < _phraseIds.length ? _phraseIds[_index + 1] : null;

  /// The step the run backed up FROM, for the backing-up screen. Null otherwise.
  MitStep? get backedUpFrom => _backedUpFrom;
  MitStep? _backedUpFrom;

  /// Items finished since the session started. Reported to the break screen so
  /// it can say how far they got, not used to decide anything.
  int get itemsFinished => _itemsFinished;
  int _itemsFinished = 0;

  // Seams for later steps. The ones below that act on a specific item receive
  // its phrase id; the session-level ones (warm-up, rest, paused) don't.
  final void Function(int phraseId)? onEnterReferencePrompt;

  /// Fired when the warm-up hum phase begins (no phrase id — it's session-level).
  final void Function()? onEnterWarmUpHum;

  /// Fired when an item's hum step (State_1c) begins, with that phrase's id. The
  /// screen synthesizes and plays the melody, then calls [endPhraseHum].
  final void Function(int phraseId)? onEnterPhraseHum;
  final void Function(int phraseId)? onEnterInputCapture;
  final void Function(int phraseId)? onLeaveInputCapture;

  /// Fired when the caregiver-verdict state begins — used to restore the tick
  /// and stop any guide/mic, for every step (capturing or not).
  final void Function()? onEnterSystemTransition;

  /// Fired when the break offer opens. The screen stops the beat here — the
  /// pulse running under a break makes it a pause rather than a rest.
  final void Function()? onEnterRest;

  /// Fired when the caregiver opens their panel. The screen stops the beat and
  /// everything else here.
  final void Function()? onEnterPaused;

  /// Fired once per judged production, when the caregiver's verdict finalizes
  /// it. The screen uses this to save the attempt to the database. A step can
  /// fire this two or three times (see [RepRule]), each with its own
  /// [AttemptResult.repNumber].
  final void Function(AttemptResult result)? onAttemptComplete;

  /// Fired when a failed step drops the person to an easier one — MIT's back-up,
  /// applied in the moment rather than at the item's next appearance.
  ///
  /// The screen needs telling because this is the one transition that must not
  /// be allowed to read as demotion: the stage moves *backwards* along the
  /// sequence, and without an explicit signal the UI would show that as a bare
  /// colour change with no explanation. [from] is the step that was failed;
  /// [to] is the easier one now running.
  final void Function(MitStep from, MitStep to)? onStepBackedUp;

  /// Fired when an item is set aside for the session — two step failures in a
  /// row, or a failure with nowhere lower to go. Carries the phrase that was set
  /// aside, since by the time the screen reacts the session has moved on to the
  /// next item.
  final void Function(int phraseId)? onItemSetAside;

  PracticeState _state = PracticeState.preparation;
  PracticeState get state => _state;

  int _index = 0;
  int get currentIndex => _index;
  int get phraseCount => _phraseIds.length;
  int get currentPhraseId => _phraseIds[_index];

  /// Word position/count for the "Word x of y" counter. One list entry is one
  /// item now, so these are just the index and the length — the consecutive-group
  /// arithmetic they used to need went away with the 3-rep block.
  int get currentWordIndex => _index;

  int get wordCount => _phraseIds.length;

  /// The phrase id at [index] in the session's running order, for a caregiver
  /// view that lists the whole session rather than only the current item.
  int phraseIdAt(int index) =>
      _phraseIds[index.clamp(0, _phraseIds.length - 1)];

  // Beats counted SINCE the current state began. A counter (incremented once per
  // beat) rather than an index delta, so a tempo change — which re-anchors the
  // metronome's beat index — can never make this jump and falsely trip a
  // beat-based timeout. (The screen drives the real advance; these are safety
  // fallbacks.)
  int _beatsInState = 0;

  int _inTimeTaps = 0;
  int get inTimeTaps => _inTimeTaps;

  final List<double> _tapPhases = [];

  // The raw per-tap stream for the current attempt (item 16a), parallel to
  // [_tapPhases]: same taps, but each carries its touch-down time + dwell so the
  // fatigue detector can read dwell trend and inter-tap-interval variance. Reset
  // per phrase (like [_tapPhases]) and flushed into the [AttemptResult].
  final List<TapEvent> _taps = [];

  // Monotonic clock for tap timestamps — started at [start], so every tap's
  // [TapEvent.downMs] is ms since the session began. A Stopwatch (not wall-clock)
  // keeps timings immune to clock changes and is trivially testable.
  final Stopwatch _clock = Stopwatch();

  int? _evaluationLabel;
  int? get evaluationLabel => _evaluationLabel;

  // Filled in by the microphone in Step 5.
  int? _latencyMs;
  int? _durationMs;
  String? _audioPath;

  /// Step 5 hook: the mic reports how long after the guide the user started
  /// speaking ([latencyMs]), how long they spoke ([durationMs]), and where the
  /// encrypted clip was saved ([audioPath], null if nothing was kept).
  void recordCaptureMetrics({
    int? latencyMs,
    int? durationMs,
    String? audioPath,
  }) {
    _latencyMs = latencyMs;
    _durationMs = durationMs;
    _audioPath = audioPath;
  }

  /// How many taps have been made during the current phrase. Rises on every
  /// touch-down and resets with the phrase; the screen watches it to acknowledge
  /// a tap the moment it lands.
  int get tapCount => _taps.length;

  /// 0..1 sync score for the current phrase so far (null if no taps yet).
  double? get currentSyncScore => syncScoreFromPhases(_tapPhases);

  /// Begin the session at the first phrase, in Preparation.
  void start() {
    _index = 0;
    _run = MitItemRun(level: level);
    _lastDecision = null;
    _itemsFinished = 0;
    _backedUpFrom = null;
    _caregiverAway = false;
    _stateBeforePause = null;
    _resetPhrase();
    _clock
      ..reset()
      ..start(); // tap timestamps are ms from here
    _state = PracticeState.preparation;
    _beatsInState = 0;
    notifyListeners();
  }

  /// Called by the metronome on every beat. [beatIndex] is informational — state
  /// timeouts count beats since entry, not absolute indices, so they survive a
  /// tempo change.
  void onBeat(int beatIndex) {
    _beatsInState++;
    // Drives per-beat UI (e.g. the phrase staff's syllable highlight) — a state
    // transition below will notify again, which is harmless (ChangeNotifier
    // coalesces within a frame).
    notifyListeners();

    switch (_state) {
      case PracticeState.warmUpHum:
        // Warm-up hum runs for a few beats, then flows into the first word.
        if (_beatsInState >= warmUpBeats) {
          _enterItem();
        }
      case PracticeState.phraseHum:
        // Safety only — the screen ends this when the melody finishes.
        if (_beatsInState >= phraseHumBeats) {
          _enter(PracticeState.referencePrompt);
        }
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
      // Preparation advances on taps; systemTransition on the caregiver; rest on
      // whoever answers the offer; sessionComplete is terminal.
      case PracticeState.backingUp:
        if (_beatsInState >= messageBeats) {
          _backedUpFrom = null;
          _enterStep();
        }
      case PracticeState.itemSetAside:
        if (_beatsInState >= messageBeats) _nextItem();
      case PracticeState.preparation:
      case PracticeState.systemTransition:
      case PracticeState.rest:
      case PracticeState.paused:
      case PracticeState.sessionComplete:
        break;
    }
  }

  /// Called when the per-phrase hum has finished playing, to move on without
  /// waiting out the beat-based safety fallback. No-op unless we're humming, so
  /// a late callback can't cut a later state short.
  ///
  /// The hum is MIT's one unjudged step: it completes and the sequence moves on,
  /// with no verdict asked for and nothing recorded.
  void endPhraseHum() {
    if (_state != PracticeState.phraseHum) return;
    _run.completeUnjudgedStep();
    _enterStep();
  }

  // Begin a new item: a fresh run through the level's sequence, from its first
  // step.
  void _enterItem() {
    _run = MitItemRun(level: level);
    _enterStep();
  }

  // Enter whatever state the run's CURRENT step calls for — the single place the
  // step sequence is translated into the screen's states.
  //
  // The hum is its own state (the screen synthesizes a melody there, and no word
  // is shown); every other step opens with the prompt, and the prompt's exit
  // routes to the mic or straight to the verdict depending on whether the step
  // yields a clean solo production. If a run has already ended — the last step
  // passed, or the item was set aside — the item is over.
  void _enterStep() {
    if (_run.outcome != ItemOutcome.running) {
      _nextItem();
      return;
    }
    if (_run.currentStep == MitStep.humMelody) {
      // [phraseHumBeats] <= 0 disables the hum outright (the unit-test
      // convention, and the escape hatch if the step ever needs turning off) —
      // then it completes silently and the sequence carries on.
      if (!phraseHumEnabled) {
        _run.completeUnjudgedStep();
        _enterStep();
        return;
      }
      _enter(PracticeState.phraseHum);
      return;
    }
    _enter(PracticeState.referencePrompt);
  }

  // Move to the next item, or end the session.
  //
  // **The app never interrupts to suggest a break.** It used to, after a set
  // number of items and after two set-asides in a row. That is now the
  // caregiver's call and theirs only, reached from the slide-out
  // ([offerRest]) — the person sitting beside the patient can see whether they
  // are tiring, and an app that decides for them gets it wrong in both
  // directions.
  void _nextItem() {
    _itemsFinished++;
    if (_index + 1 >= _phraseIds.length) {
      _enter(PracticeState.sessionComplete);
      return;
    }
    _advanceToNextItem();
  }

  /// Offer a break, from the caregiver's panel. No-op once the session is over.
  void offerRest() {
    if (_state == PracticeState.sessionComplete) return;
    _stateBeforePause = _state == PracticeState.paused
        ? _stateBeforePause
        : _state;
    _caregiverAway = false;
    _enter(PracticeState.rest);
  }

  void _advanceToNextItem() {
    _index++;
    _resetPhrase();
    // "Lock once, then flow": the beat lock happens only at the start of a
    // session (State_1). Later items skip Preparation and open at the first step
    // of their sequence — and a break does NOT re-lock the beat either.
    _enterItem();
  }

  /// Whether the caregiver is currently away in their panel. While true the
  /// patient's screen says so and shows no pulse; once they are back it becomes
  /// false and the screen offers to carry on, waiting for a tap.
  bool get caregiverAway => _caregiverAway;
  bool _caregiverAway = false;

  /// The state to come back to. A break offer that was on screen when the
  /// caregiver left is still owed an answer when they return.
  PracticeState? _stateBeforePause;

  /// Open the caregiver's panel: stop everything, here, now.
  ///
  /// No-op at the session's end, and no-op if already paused — a second call
  /// from a re-entered panel must not lose [_stateBeforePause].
  void pauseForCaregiver() {
    if (_state == PracticeState.sessionComplete ||
        _state == PracticeState.paused) {
      return;
    }
    _stateBeforePause = _state;
    _caregiverAway = true;
    _enter(PracticeState.paused);
  }

  /// The caregiver has closed the panel. The session does **not** start again
  /// on its own — this only changes what the patient's screen offers, and
  /// [resumeAfterCaregiver] is what actually restarts anything.
  void caregiverReturned() {
    if (_state != PracticeState.paused || !_caregiverAway) return;
    _caregiverAway = false;
    notifyListeners();
  }

  /// Carry on, on a tap. The current step restarts **from its beginning** —
  /// dropping back into the middle of a phrase someone was halfway through
  /// singing is worse than starting it again.
  void resumeAfterCaregiver() {
    if (_state != PracticeState.paused) return;
    _caregiverAway = false;
    final before = _stateBeforePause;
    _stateBeforePause = null;
    // A break offer still owed an answer comes back rather than being skipped.
    if (before == PracticeState.rest) {
      _enter(PracticeState.rest);
      return;
    }
    if (before == PracticeState.preparation ||
        before == PracticeState.warmUpHum) {
      _enter(PracticeState.preparation);
      return;
    }
    _resetPhrase();
    _enterStep();
  }

  /// Keep going. Deliberately the same size and the same distance from the
  /// thumb as resting: declining must cost nothing.
  ///
  /// The break was offered from the caregiver's panel mid-item, so this returns
  /// to where the session was rather than skipping to the next item.
  void resumeFromRest() {
    if (_state != PracticeState.rest) return;
    final before = _stateBeforePause;
    _stateBeforePause = null;
    if (before == PracticeState.preparation ||
        before == PracticeState.warmUpHum) {
      _enter(PracticeState.preparation);
      return;
    }
    _resetPhrase();
    _enterStep();
  }

  /// Accept the break and stop for today. The attempts already made are saved —
  /// stopping early is not a failed session, it is a shorter one.
  void finishSessionEarly() {
    if (_state == PracticeState.sessionComplete) return;
    _stateBeforePause = null;
    _enter(PracticeState.sessionComplete);
  }

  /// Whether a phrase is being PRODUCED right now — its melody hummed, the model
  /// sounding, or the person speaking — and so whether the caregiver should be
  /// tapping.
  ///
  /// In canonical MIT the caregiver taps the patient's left hand once per
  /// syllable through **every** production at **every** step: it is one of the
  /// two active ingredients, not a warm-up drill. But the tapping is
  /// **phrase-locked, not clock-locked** — it starts and ends with the phrase, so
  /// a three-syllable phrase gets three taps and then the hand rests. The gaps
  /// carry none: the count-in before unison, the six-second silence at R5, the
  /// pause before a verdict. Cueing a tap on every beat of the session (which is
  /// what this used to do) turns a phrase-shaped gesture into a metronome — a
  /// different, easier thing than the therapy asks for.
  ///
  /// The screen owns the audio timing, so it opens and closes the window via
  /// [beginProduction] / [endProduction]. Entering any state closes it, so a
  /// window can never leak past the production it belongs to.
  ///
  /// Tapping is a support, never a gate: nothing about the taps affects how the
  /// sequence moves. This getter exists so the screen can CUE the tapping, which
  /// is what was missing — taps have always been recorded.
  bool get tappingExpected =>
      _producing && _state != PracticeState.sessionComplete;

  bool _producing = false;
  int _productionStartBeat = 0;

  /// Beats since the production in progress actually started sounding — the
  /// screen calls [beginProduction] on the audio's real start (after any
  /// beat-sync wait), so this is exact, not the step's elapsed time. Drives the
  /// phrase staff's per-beat syllable highlight; `0` when nothing is producing.
  int get beatsIntoProduction =>
      _producing ? _beatsInState - _productionStartBeat : 0;

  /// Open the tapping window — a production has begun (hum, model, or the
  /// person's own attempt). Idempotent.
  void beginProduction() {
    if (_producing) return;
    _producing = true;
    _productionStartBeat = _beatsInState;
    notifyListeners();
  }

  /// Close the tapping window — the production has finished and the hand rests
  /// until the next one. Idempotent.
  void endProduction() {
    if (!_producing) return;
    _producing = false;
    notifyListeners();
  }

  /// Step 4: called when the audio guide finishes playing, to open capture as
  /// soon as the whole word has been heard (rather than after a fixed number of
  /// beats). No-op unless we're in Reference_Prompt. The beat-based [guideBeats]
  /// timeout in [onBeat] remains as a safety fallback if completion never fires.
  void endReferencePrompt() {
    if (_state != PracticeState.referencePrompt) return;
    _leaveReferencePrompt();
  }

  // Leave Reference_Prompt for the right next state given the current MIT step:
  // a step that yields a clean solo production opens the mic; a unison step goes
  // straight to the caregiver verdict, because the model sounding aloud makes
  // the recording useless.
  void _leaveReferencePrompt() {
    if (currentStep.cleanCapture) {
      _enter(PracticeState.inputCapture);
      return;
    }
    _enter(PracticeState.systemTransition);
  }

  /// Step 5: called by the microphone when it auto-closes on ~4.5 s of silence,
  /// to end capture *before* the beat-based safety timeout in [onBeat]. No-op
  /// unless we're currently capturing, so a late callback can't double-fire.
  void endCapture() {
    if (_state != PracticeState.inputCapture) return;
    onLeaveInputCapture?.call(currentPhraseId);
    _enter(PracticeState.systemTransition);
  }

  /// Called on touch-DOWN when the user taps the screen. [phase] is the metronome
  /// phase at the moment of the tap (0.0 = on the beat). Taps are collected for
  /// the sync score AND as a raw [TapEvent] (item 16a); in Preparation, enough
  /// in-time taps advance to State_2. The matching [registerTapRelease] fills in
  /// the dwell on finger-up.
  void registerTap(double phase) {
    if (_state == PracticeState.sessionComplete) return;
    _tapPhases.add(phase);
    _taps.add(TapEvent(downMs: _clock.elapsedMilliseconds, phase: phase));

    if (_state == PracticeState.preparation &&
        isInTime(phase, tolerance: lockTolerance)) {
      _inTimeTaps++;
      if (_inTimeTaps >= tapsToAdvance) {
        // Beat locked → the warm-up's hum phase, then the first word. Tapping
        // only ends the warm-up; it can never advance a word's rung. A zero-length
        // warm-up ([warmUpBeats] <= 0) flows straight into the first word.
        _enter(PracticeState.warmUpHum);
        if (warmUpBeats <= 0) _enterItem();
        return;
      }
    }
    notifyListeners();
  }

  /// Called on touch-UP for the most recent tap, to record its dwell (press
  /// duration). Sets the dwell on the latest [TapEvent] that doesn't have one yet;
  /// a no-op if the release arrives with no matching down (e.g. after a phrase
  /// reset). Dwell stays null when the release is never observed — the fatigue
  /// detector treats a null dwell as "not measured", not zero.
  void registerTapRelease() {
    for (var i = _taps.length - 1; i >= 0; i--) {
      if (_taps[i].dwellMs == null) {
        _taps[i].dwellMs = (_clock.elapsedMilliseconds - _taps[i].downMs).clamp(
          0,
          1 << 30,
        );
        return;
      }
    }
  }

  /// Demo only: re-run the current step from the top of its prompt, without
  /// recording an attempt or touching the run's verdict history. The screen calls
  /// this after a presenter jumps the sequence from the in-session step picker,
  /// so the new step's behaviour (model playback, cues, stage tint) plays out at
  /// once. Safe from any non-terminal state.
  void restartCurrentStep() {
    if (_state == PracticeState.sessionComplete) return;
    _resetPhrase();
    _enterStep();
  }

  /// Demo only: jump the current item's run to [step], if the level's sequence
  /// contains it, and re-run it immediately. Nothing is judged or persisted — a
  /// demonstration must never disturb real therapy history.
  void demoJumpToStep(MitStep step) {
    if (_state == PracticeState.sessionComplete) return;
    if (!_run.jumpTo(step)) return;
    _resetPhrase();
    _enterStep();
  }

  /// The caregiver's verdict in State_4: 0 = Fail, 1 = Pass, 2 = Unsure.
  /// Records it against the current MIT step, then does whatever the step's
  /// verdicts now call for.
  void setEvaluation(int label) {
    if (_state != PracticeState.systemTransition) return;
    _finishAttempt(label);
  }

  // Finalize the current production with [label], hand it to the screen to save,
  // then let MIT's rules decide what happens next.
  //
  // The three outcomes ([RepDecision]) all land in the same place — whatever step
  // the run is on after the verdict is the step we run next:
  //   * `again`  — the step is unresolved, so it is produced once more;
  //   * `passed` — the run has advanced, so the next step runs (or the item is
  //                complete);
  //   * `failed` — the run has BACKED UP a step, and that easier step runs now.
  // The back-up is what makes support immediate: the person is dropped to firmer
  // ground in the moment, not at the word's next appearance.
  void _finishAttempt(int label) {
    _evaluationLabel = label;
    final step = _run.currentStep;
    final rep = _run.repNumber;

    // Hand the finalized attempt to the screen for saving, BEFORE we reset.
    onAttemptComplete?.call(
      AttemptResult(
        phraseId: currentPhraseId,
        syncScore: currentSyncScore,
        evaluationLabel: label,
        latencyMs: _latencyMs,
        durationMs: _durationMs,
        localEncryptedAudioPath: _audioPath,
        step: step,
        repNumber: rep,
        taps: List<TapEvent>.of(
          _taps,
        ), // the raw stream for this attempt (item 16a)
      ),
    );

    final decision = _run.recordVerdict(Verdict.fromLabel(label));
    _lastDecision = decision;

    // Announce the two moves that need explaining. Both are read off the run
    // BEFORE [_enterStep] advances past them — a set-aside in particular is
    // invisible a moment later, because moving to the next item replaces the run.
    // Per-production scratch (taps, mic metrics) belongs to the production just
    // finished — clear it whether the next thing is another rep of this step, a
    // different step, or a different item.
    _resetPhrase();

    // The two moves that need explaining get a held moment of their own before
    // the session carries on. Both are announced from the state they land in, so
    // the screen has something to render rather than a toast over the next step.
    if (decision == RepDecision.failed) {
      if (_run.outcome == ItemOutcome.setAside) {
        onItemSetAside?.call(currentPhraseId);
        if (messageBeats > 0) {
          _enter(PracticeState.itemSetAside);
          return;
        }
        _nextItem();
        return;
      }
      onStepBackedUp?.call(step, _run.currentStep);
      if (messageBeats > 0) {
        _backedUpFrom = step;
        _enter(PracticeState.backingUp);
        return;
      }
    }

    _enterStep();
  }

  // Enter a new state: reset the beats-in-state counter, run its seam, notify.
  void _enter(PracticeState next) {
    _state = next;
    _beatsInState = 0;
    // A tapping window belongs to the production that opened it. Closing it here
    // means a stale window can never survive into the next state — the screen
    // re-opens it when the next hum/model/attempt actually starts.
    _producing = false;
    switch (next) {
      case PracticeState.warmUpHum:
        onEnterWarmUpHum?.call();
      case PracticeState.phraseHum:
        onEnterPhraseHum?.call(currentPhraseId);
      case PracticeState.referencePrompt:
        onEnterReferencePrompt?.call(currentPhraseId);
      case PracticeState.inputCapture:
        onEnterInputCapture?.call(currentPhraseId);
      case PracticeState.systemTransition:
        onEnterSystemTransition?.call();
      case PracticeState.rest:
        onEnterRest?.call();
      case PracticeState.paused:
        onEnterPaused?.call();
      default:
        break;
    }
    notifyListeners();
  }

  void _resetPhrase() {
    _inTimeTaps = 0;
    _tapPhases.clear();
    _taps.clear();
    _evaluationLabel = null;
    _latencyMs = null;
    _durationMs = null;
    _audioPath = null;
  }
}
