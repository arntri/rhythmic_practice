/// Canonical MIT's level/step structure — the therapy's actual shape, replacing
/// the between-session support ladder the app used to run.
///
/// The difference matters. Under the old model a word **sat** at one rung and
/// ran three reps there, and an engine moved it up or down between sessions, so
/// a word might take weeks to travel from unison to solo. In MIT the clinician
/// runs **the whole step sequence on every item, every session**, and backs up a
/// step the instant one fails. The sequence is the therapy; the ladder was our
/// re-engineering of it.
///
/// One deliberate departure remains, and it is the caregiver's, not MIT's: each
/// judged step is produced **twice, or three times at worst**, so an untrained
/// judge gets a second look before a verdict sticks. See [RepRule].
library;

import 'dart:math' as math;

/// MIT's three levels. The **patient** sits at one of these — not the word.
///
/// This is the other half of the correction: our "level" used to mean a phrase's
/// syllable count, which confused how long an item is with how much support the
/// person needs. In MIT a level is a step sequence chosen for the person's
/// severity, and every item they practise runs that sequence.
enum MitLevel {
  /// Level I — most severe. Humming and unison only; the person is never asked
  /// to produce independently, so nothing here can be failed for not speaking.
  one,

  /// Level II — the core of MIT. Unison through to answering a question.
  two,

  /// Level III — for items already established. Retrieval rather than echo, and
  /// then the bridge back out of song: Sprechgesang, then ordinary speech.
  three,
}

extension MitLevelInfo on MitLevel {
  /// 'I' / 'II' / 'III' — how MIT names its levels, and how the caregiver-facing
  /// UI shows them.
  String get roman => switch (this) {
    MitLevel.one => 'I',
    MitLevel.two => 'II',
    MitLevel.three => 'III',
  };

  String get title => 'Level $roman';

  String get description => switch (this) {
    MitLevel.one =>
      'Humming and unison only — never asked to produce on their own.',
    MitLevel.two => 'MIT\'s core sequence: unison through to answering a question.',
    MitLevel.three =>
      'Established phrases: retrieval, then the bridge back to ordinary speech.',
  };
}

/// One step within a level's sequence.
enum MitStep {
  /// The phrase's melody hummed twice, no words, while the caregiver taps. The
  /// person listens (and may hum along) — never judged: it is how the melody is
  /// handed over before there is anything to retrieve.
  humMelody,

  /// The person hums the melody in unison. Level I's own production step —
  /// sound, not words.
  humUnison,

  /// Intone the phrase in unison with the model.
  intoneUnison,

  /// Unison with the model fading out, so the person carries the end alone.
  unisonFading,

  /// Listen to the model, then repeat it straight back.
  immediateRepeat,

  /// Listen, hold six seconds of silence, then produce it — retrieval rather
  /// than echo.
  delayedRepeat,

  /// Answer a question with the phrase. MIT's Step 5, and the only step that
  /// asks the person to *use* the phrase rather than reproduce it.
  probeQuestion,

  /// **Sprechgesang** — speech-song. The same rhythm and stress as the intoned
  /// phrase, and the hand goes on tapping, but the pitch contour is dropped: it
  /// is *spoken* with exaggerated prosody rather than sung.
  ///
  /// This is MIT's exit ramp, and it is not optional. Without it a patient ends
  /// up able to produce a phrase only when it is sung — which is a trick that
  /// lives in one modality, not recovered language. Sprechgesang withdraws the
  /// melodic scaffold while keeping the rhythmic one, so there is something left
  /// to hold onto on the way out.
  sprechgesang,

  /// Ordinary spoken prosody, unaccompanied. The last thing MIT asks for, and
  /// the point of all of it: the phrase said the way anyone would say it.
  spokenProduction,
}

extension MitStepInfo on MitStep {
  /// Whether the person produces at this step, and so whether the caregiver
  /// judges it. Only [MitStep.humMelody] is exempt — there the melody is being
  /// given to them.
  bool get isJudged => this != MitStep.humMelody;

  /// Whether a model sounds at this step. Note [MitStep.sprechgesang] plays a
  /// *different* model — the slow-spoken clip, not the intoned guide — and
  /// [MitStep.spokenProduction] plays none at all.
  bool get playsModel =>
      this == MitStep.humMelody ||
      this == MitStep.humUnison ||
      this == MitStep.intoneUnison ||
      this == MitStep.unisonFading ||
      this == MitStep.immediateRepeat ||
      this == MitStep.delayedRepeat ||
      this == MitStep.sprechgesang;

  /// Whether this step is still *intoned* — sung on the two pitches. The last
  /// two steps of Level III are deliberately not: dropping the tune while
  /// keeping the tapping is what the bridge out of song consists of.
  bool get isIntoned =>
      this != MitStep.sprechgesang && this != MitStep.spokenProduction;

  /// Whether the model is still sounding while the person produces. A unison
  /// step can't be recorded — the mic would capture the model as much as the
  /// person.
  bool get isUnison =>
      this == MitStep.humUnison ||
      this == MitStep.intoneUnison ||
      this == MitStep.unisonFading;

  /// Whether this step yields a clean solo production worth recording and
  /// scoring against the guide.
  bool get cleanCapture =>
      this == MitStep.immediateRepeat ||
      this == MitStep.delayedRepeat ||
      this == MitStep.probeQuestion ||
      this == MitStep.sprechgesang ||
      this == MitStep.spokenProduction;

  String get title => switch (this) {
    MitStep.humMelody => 'Listen to the tune',
    MitStep.humUnison => 'Hum it together',
    MitStep.intoneUnison => 'Say it together',
    MitStep.unisonFading => 'Together, model fades',
    MitStep.immediateRepeat => 'Repeat after the model',
    MitStep.delayedRepeat => 'Delayed repeat',
    MitStep.probeQuestion => 'Answer the question',
    MitStep.sprechgesang => 'Say it, don\'t sing it',
    MitStep.spokenProduction => 'Just say it',
  };
}

/// The step sequence for [level] — run in order, on every item, every session.
///
/// Level I stops short of independent production by design. Level II is MIT's
/// canonical five steps. Level III drops the scaffolding: an item that reaches
/// it is established, so the work is holding it through a silence, using it to
/// answer something — and then **coming off the melody**, first into
/// Sprechgesang and finally into ordinary speech.
///
/// That last pair is the part of MIT most often left out, and leaving it out is
/// the method's known failure mode: a patient who can say the phrase only while
/// singing it has not generalised anything.
List<MitStep> stepsFor(MitLevel level) => switch (level) {
  MitLevel.one => const [
    MitStep.humMelody,
    MitStep.humUnison,
    MitStep.intoneUnison,
  ],
  MitLevel.two => const [
    MitStep.humMelody,
    MitStep.intoneUnison,
    MitStep.unisonFading,
    MitStep.immediateRepeat,
    MitStep.probeQuestion,
  ],
  MitLevel.three => const [
    MitStep.delayedRepeat,
    MitStep.probeQuestion,
    MitStep.sprechgesang,
    MitStep.spokenProduction,
  ],
};

/// Caregiver verdict on one production. Matches the stored label ints.
enum Verdict {
  fail, // 0
  pass, // 1
  unsure; // 2

  static Verdict fromLabel(int label) => switch (label) {
    1 => Verdict.pass,
    2 => Verdict.unsure,
    _ => Verdict.fail,
  };

  int get label => switch (this) {
    Verdict.fail => 0,
    Verdict.pass => 1,
    Verdict.unsure => 2,
  };
}

/// What to do after the verdicts collected so far at one step.
enum RepDecision {
  /// Ask for another production of the same phrase at this step.
  again,

  /// The step is passed — move to the next step in the sequence.
  passed,

  /// The step is failed — back up one step (see [MitItemRun]).
  failed,
}

/// The one deliberate departure from MIT, and it is the caregiver's: each judged
/// step is produced **twice**, and a third time only when the first two leave
/// real doubt.
///
/// A trained clinician judges a production once and is right. An untrained
/// caregiver watching their parent is not so sure, and the cost of a wrong
/// verdict here is a step wrongly failed and a person wrongly backed up. So:
///
/// - **Pass, Pass** → passed. No third; two clean productions is enough.
/// - **Fail, Fail** → failed. No third either — making someone try a third time
///   after two clear failures is the opposite of errorless practice.
/// - **anything else** (any Unsure, or one of each) → a third production
///   decides it, on a simple majority: two Passes of the three passes the step.
///
/// Note the asymmetry is deliberate: certainty in either direction stops at two,
/// and only doubt costs a third rep.
abstract final class RepRule {
  /// Most productions a single step will ever ask for.
  static const int maxReps = 3;

  /// Decide what happens after [verdicts] (in the order they were given) at one
  /// step.
  static RepDecision decide(List<Verdict> verdicts) {
    final passes = verdicts.where((v) => v == Verdict.pass).length;
    final fails = verdicts.where((v) => v == Verdict.fail).length;

    if (verdicts.length < 2) return RepDecision.again;

    if (verdicts.length == 2) {
      if (passes == 2) return RepDecision.passed;
      if (fails == 2) return RepDecision.failed;
      return RepDecision.again; // doubt → the deciding third
    }

    // Third production in: simple majority, and a tie of unsures fails safe —
    // "we could not tell" is not evidence the step was passed.
    return passes >= 2 ? RepDecision.passed : RepDecision.failed;
  }
}

/// The outcome of running one item through its level's sequence.
enum ItemOutcome {
  /// Still working through the sequence.
  running,

  /// Every step passed — the item is complete for this session.
  completed,

  /// Set aside: two step failures in a row, with no lower step to back up to.
  /// MIT's rule — the clinician moves on rather than drilling a failure.
  setAside,
}

/// One item's run through its level's step sequence, with MIT's back-up rule.
///
/// **Back-up:** a failed step drops the person to the *previous* step and re-runs
/// it, then comes back up to re-attempt the one they missed. Support is restored
/// immediately, in the moment — not at the next session, which is what the old
/// ladder did.
///
/// **Setting aside:** two consecutive step failures, or a failure with nowhere
/// lower to go, ends the item for this session. Drilling a failure is not what
/// MIT does.
class MitItemRun {
  MitItemRun({required this.level})
    : _steps = stepsFor(level),
      assert(stepsFor(level).isNotEmpty);

  final MitLevel level;
  final List<MitStep> _steps;

  int _index = 0;
  int _consecutiveStepFailures = 0;
  ItemOutcome _outcome = ItemOutcome.running;
  final List<Verdict> _stepVerdicts = [];

  /// Every verdict given during this run, in order, across all steps — what gets
  /// persisted and what the level criterion is computed from.
  final List<({MitStep step, Verdict verdict})> history = [];

  ItemOutcome get outcome => _outcome;

  /// The step being worked on right now.
  MitStep get currentStep => _steps[_index];

  /// Verdicts given so far at [currentStep] (0–3).
  List<Verdict> get currentStepVerdicts => List.unmodifiable(_stepVerdicts);

  /// Which production of the current step is next (1-based) — for "attempt 2 of
  /// 3" style cues.
  int get repNumber => _stepVerdicts.length + 1;

  /// Whether the current step is judged at all. [MitStep.humMelody] is not: it
  /// runs, and the sequence moves on without a verdict.
  bool get isJudged => currentStep.isJudged;

  /// Advance past an unjudged step (the hum). No-op on a judged one.
  void completeUnjudgedStep() {
    if (_outcome != ItemOutcome.running || currentStep.isJudged) return;
    _advance();
  }

  /// **Demonstration only.** Move the run to [step] without judging anything,
  /// so a presenter can show any stage of the sequence on demand. Returns false
  /// (and changes nothing) if this level's sequence has no such step, or the run
  /// has already ended.
  ///
  /// Deliberately does NOT touch [history] or the consecutive-failure count: a
  /// demo must leave the therapy record exactly as it found it.
  bool jumpTo(MitStep step) {
    if (_outcome != ItemOutcome.running) return false;
    final i = _steps.indexOf(step);
    if (i < 0) return false;
    _index = i;
    _stepVerdicts.clear();
    return true;
  }

  /// Record one caregiver verdict at the current step and apply MIT's rules.
  ///
  /// Returns the resulting [RepDecision] so the caller knows whether to ask for
  /// another production, move on, or back up.
  RepDecision recordVerdict(Verdict verdict) {
    if (_outcome != ItemOutcome.running || !currentStep.isJudged) {
      return RepDecision.again;
    }

    _stepVerdicts.add(verdict);
    history.add((step: currentStep, verdict: verdict));

    final decision = RepRule.decide(_stepVerdicts);
    switch (decision) {
      case RepDecision.again:
        break;
      case RepDecision.passed:
        _consecutiveStepFailures = 0;
        _advance();
      case RepDecision.failed:
        _consecutiveStepFailures++;
        _backUp();
    }
    return decision;
  }

  // Move to the next step, or finish the item.
  void _advance() {
    _stepVerdicts.clear();
    if (_index + 1 >= _steps.length) {
      _outcome = ItemOutcome.completed;
      return;
    }
    _index++;
  }

  // MIT's back-up: drop one step and re-run it. Two failures in a row, or a
  // failure at the first step with nowhere lower to go, sets the item aside.
  void _backUp() {
    _stepVerdicts.clear();
    if (_consecutiveStepFailures >= 2 || _index == 0) {
      _outcome = ItemOutcome.setAside;
      return;
    }
    _index--;
  }

  /// Pass rate across every judged production in this run — the number the level
  /// criterion is built from. Null when nothing was judged.
  double? get passRate {
    if (history.isEmpty) return null;
    final passes = history.where((h) => h.verdict == Verdict.pass).length;
    return passes / history.length;
  }
}

/// MIT's advancement criterion, applied where MIT applies it: to the **person's
/// level**, not to a single word.
///
/// The old app spent this number on a per-word syllable-tier gate. In MIT it is
/// what moves someone from Level I to II to III — roughly 90% correct across the
/// items they are practising, sustained rather than sampled once.
abstract final class LevelCriterion {
  /// Proportion of judged productions that must pass.
  static const double passRate = 0.9;

  /// How many recent sessions the rate is measured over.
  static const int window = 10;

  /// Whether [sessionPassRates] (oldest → newest) clears the criterion for
  /// moving up from [current]. Level III is the top; nothing advances past it.
  static bool shouldAdvance(
    List<double> sessionPassRates, {
    required MitLevel current,
  }) {
    if (current == MitLevel.three) return false;
    if (sessionPassRates.length < window) return false;
    final recent = sessionPassRates.sublist(sessionPassRates.length - window);
    final mean = recent.reduce((a, b) => a + b) / recent.length;
    return mean >= passRate;
  }

  /// One level up, clamped at the top.
  static MitLevel raised(MitLevel level) =>
      MitLevel.values[math.min(level.index + 1, MitLevel.values.length - 1)];

  /// One level down, clamped at the bottom.
  static MitLevel lowered(MitLevel level) =>
      MitLevel.values[math.max(level.index - 1, 0)];
}
