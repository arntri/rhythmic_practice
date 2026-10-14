import 'mit_sequence.dart';

/// The timing knobs for each MIT step, in one testable place.
///
/// These were private constants inside the practice screen, which made the most
/// clinically load-bearing number in the app — the delayed-repeat gap — invisible
/// and untestable. They are protocol values, not styling: shortening
/// [delayedRepeatMs] changes what the therapy asks of the person.

/// Unison steps: pause after the model finishes before the caregiver's verdict,
/// so the person can finish saying it together. Nothing is recorded at these
/// steps — the model playing aloud makes the mic useless — so this is simply
/// room to finish.
const int unisonTailMs = 1800;

/// Immediate repeat: the breath between the model finishing and the mic opening.
/// Deliberately short — at this step the phrase is *meant* to still be ringing
/// in the ear.
const int repeatBreathMs = 1200;

/// Delayed repeat: the silence between hearing the phrase and being asked to
/// produce it.
///
/// **Six seconds, per the MIT protocol.** The delay is the entire point of this
/// step: a short gap lets the person echo a phrase still held in auditory
/// memory, whereas a long one forces genuine retrieval — which is the skill the
/// delayed repeat exists to train. The app previously waited 2.2 s, comfortably
/// inside echo range, which made it a slightly slower immediate repeat rather
/// than a different task.
///
/// Six beats at the default 60 BPM, so the pulse keeps running underneath and
/// the caregiver keeps tapping through it: the silence is *held*, not empty.
const int delayedRepeatMs = 6000;

/// Unison steps: seconds of count-in before the model plays, so the person is
/// set to come in with it.
const int unisonPrepSeconds = 5;

/// [MitStep.spokenProduction]: the brief "get ready" shown before the mic opens.
/// There is no model at this step — nothing is played and nothing is sung — so
/// this small hold is all the preparation there is.
const int spokenPromptMs = 2500;

/// How long to hold after the model (or the probe question) finishes, before the
/// next thing happens — the mic opening, or the verdict at the unison steps.
int afterModelMs(MitStep step) => switch (step) {
  // Retrieval, not echo — the whole reason this step exists.
  MitStep.delayedRepeat => delayedRepeatMs,
  // A breath, then produce: the immediate repeat, answering the probe, and
  // echoing the spoken (un-sung) model at the Sprechgesang step.
  MitStep.immediateRepeat ||
  MitStep.probeQuestion ||
  MitStep.sprechgesang => repeatBreathMs,
  // Nothing is played at the last step, so the hold before the mic is simply
  // the get-ready.
  MitStep.spokenProduction => spokenPromptMs,
  // Hum and unison steps: room to finish together, then the verdict.
  _ => unisonTailMs,
};
