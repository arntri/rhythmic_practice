import 'package:flutter/material.dart';

import '../practice/mit_sequence.dart';

/// The practice screen's colour system, from the design canvas
/// (`Practice Layers.dc.html`).
///
/// **Two hues, and they mean two people.** Green is the patient's field, carried
/// over from the plant on the home screen. **Lavender is the caregiver's layer
/// and nothing else** — the verdict panel, the slide control, the portrait panel
/// behind it — so the two people using the phone always know which marks are
/// theirs. Lavender never appears in the patient's field, and green never
/// appears on a caregiver control.
///
/// **The field drains as the melody is withdrawn.** The nine stages walk from a
/// cool green (hue 168) to a warm near-neutral (hue 95), losing chroma the whole
/// way, so the last two steps look almost colourless *on purpose*: the canvas is
/// losing the same thing the patient is. It is the only place in the app where
/// colour carries meaning, and what it carries is how much scaffolding is left.
///
/// Every value below is the design's, computed from its OKLCH formula and
/// converted to sRGB — not eyeballed.
abstract final class PracticePalette {
  /// The nine stages, in sequence order. Indexed by [stageIndexOf].
  static const List<StageTint> stages = [
    StageTint(
      // Listen to the tune — the greenest, coolest end. All the scaffolding.
      fieldTop: Color(0xFFEBFDF5),
      fieldBottom: Color(0xFFCAF2E1),
      glow: Color(0xFFEBFFFA),
      edge: Color(0xFF62B194),
      ink: Color(0xFF013728),
      stepFg: Color(0xFF3E5D51),
      accent: Color(0xFF007856),
    ),
    StageTint(
      // Hum it together
      fieldTop: Color(0xFFEAFDF2),
      fieldBottom: Color(0xFFC7F4DA),
      glow: Color(0xFFEDFFF7),
      edge: Color(0xFF6DB38F),
      ink: Color(0xFF063722),
      stepFg: Color(0xFF405D4D),
      accent: Color(0xFF007948),
    ),
    StageTint(
      // Say it together — the greenest the field ever gets, and the fullest the
      // screen ever is.
      fieldTop: Color(0xFFEAFEEE),
      fieldBottom: Color(0xFFC7F5D1),
      glow: Color(0xFFEFFFF4),
      edge: Color(0xFF79B589),
      ink: Color(0xFF0D371C),
      stepFg: Color(0xFF425D49),
      accent: Color(0xFF007935),
    ),
    StageTint(
      // Together, model fades
      fieldTop: Color(0xFFEDFDED),
      fieldBottom: Color(0xFFCDF3CF),
      glow: Color(0xFFF1FFF2),
      edge: Color(0xFF7EB381),
      ink: Color(0xFF153619),
      stepFg: Color(0xFF455C46),
      accent: Color(0xFF19772C),
    ),
    StageTint(
      // Repeat after the model
      fieldTop: Color(0xFFF0FCED),
      fieldBottom: Color(0xFFD5F1CE),
      glow: Color(0xFFF3FFF0),
      edge: Color(0xFF83AF79),
      ink: Color(0xFF1B3516),
      stepFg: Color(0xFF495B45),
      accent: Color(0xFF357425),
    ),
    StageTint(
      // Delayed repeat
      fieldTop: Color(0xFFF2FBEE),
      fieldBottom: Color(0xFFDBEED0),
      glow: Color(0xFFF5FFEE),
      edge: Color(0xFF87AB71),
      ink: Color(0xFF213414),
      stepFg: Color(0xFF4C5A43),
      accent: Color(0xFF467124),
    ),
    StageTint(
      // Answer the question
      fieldTop: Color(0xFFF5FAEF),
      fieldBottom: Color(0xFFE1ECD3),
      glow: Color(0xFFF8FFEC),
      edge: Color(0xFF90A473),
      ink: Color(0xFF273311),
      stepFg: Color(0xFF505942),
      accent: Color(0xFF546D23),
    ),
    StageTint(
      // Say it, don't sing it — the tune is coming away, and so is the colour.
      fieldTop: Color(0xFFF8F8F2),
      fieldBottom: Color(0xFFE8E9DA),
      glow: Color(0xFFFEFFF1),
      edge: Color(0xFF999A7D),
      ink: Color(0xFF2F300E),
      stepFg: Color(0xFF565741),
      accent: Color(0xFF666728),
    ),
    StageTint(
      // Just say it — near-neutral. Nothing left to scaffold with.
      fieldTop: Color(0xFFF9F8F4),
      fieldBottom: Color(0xFFE9E7E0),
      glow: Color(0xFFFFFDF7),
      edge: Color(0xFF999587),
      ink: Color(0xFF352D0E),
      stepFg: Color(0xFF5B5541),
      accent: Color(0xFF70632F),
    ),
  ];

  /// Where a step sits on the drain. Not [MitStep.index] — the enum appends new
  /// values at the end so stored attempt integers keep their meaning, which
  /// leaves it in a different order from the sequence.
  static int stageIndexOf(MitStep step) => switch (step) {
    MitStep.humMelody => 0,
    MitStep.humUnison => 1,
    MitStep.intoneUnison => 2,
    MitStep.unisonFading => 3,
    MitStep.immediateRepeat => 4,
    MitStep.delayedRepeat => 5,
    MitStep.probeQuestion => 6,
    MitStep.sprechgesang => 7,
    MitStep.spokenProduction => 8,
  };

  static StageTint of(MitStep step) => stages[stageIndexOf(step)];

  /// The warm-up's two stages. Not MIT steps, so they borrow the first two
  /// tints rather than having their own place on the drain.
  static StageTint get warmUpTap => stages[0];
  static StageTint get warmUpHum => stages[1];

  // --- The microphone -------------------------------------------------------
  // The one state change that ignores the stage tint, because it has to mean the
  // same thing at every step.

  /// The wash that rises from the patient's side of the field while recording.
  static const micWash = Color(0xFFBBEDC4);
  static const recordingBg = Color(0xFFD2F6D8);
  static const recordingFg = Color(0xFF005E26);

  // --- The caregiver's layer ------------------------------------------------
  // Lavender, and it appears nowhere in the patient's field.

  static const lavender = Color(0xFF7652AC);
  static const lavenderInk = Color(0xFF493766);
  static const dockBg = Color(0xFFF5F0FF);
  static const slideTrack = Color(0xFFEBE3FE);

  // --- The verdict ----------------------------------------------------------
  // Green for yes, lavender for maybe, warm sand for not yet — the caregiver's
  // three hues. **Never red.** "Not yet" is where support goes, not a failure.

  static const yesBg = Color(0xFFD5FADB);
  static const yesFg = Color(0xFF00531B);
  static const yesBd = Color(0xFF94CF9F);
  static const maybeBg = Color(0xFFF2E9FF);
  static const maybeFg = Color(0xFF523779);
  static const maybeBd = Color(0xFFCBBAEB);
  static const notYetBg = Color(0xFFFFECC9);
  static const notYetFg = Color(0xFF784900);
  static const notYetBd = Color(0xFFE4C18C);

  // --- The phrase staff -----------------------------------------------------

  /// A slot the beat has not reached yet.
  static const slotIdleFg = Color(0xFF455142);
  static const slotIdleBd = Color(0xFF778574);

  /// Step dots: passed, and still to come.
  static const dotDone = Color(0xFF6C896C);
  static const dotFuture = Color(0xFF7D8B7A);

  /// The tap cue's dot when the hand is resting.
  static const tapResting = Color(0xFFB1BBAF);
}

/// One stage's colours. The field is a gradient, not a flat fill — the design
/// runs it 172° so the light sits toward the top and the weight toward the
/// bottom, where the patient's hands are.
class StageTint {
  const StageTint({
    required this.fieldTop,
    required this.fieldBottom,
    required this.glow,
    required this.edge,
    required this.ink,
    required this.stepFg,
    required this.accent,
  });

  final Color fieldTop;
  final Color fieldBottom;

  /// The radial swell that peaks on the beat.
  final Color glow;

  /// The inset border that pulses with it. On the drained stages it holds its
  /// weight by going *darker* rather than greener — the colour is the thing
  /// being taken away, so it cannot be what carries the pulse.
  final Color edge;

  /// Text on the field.
  final Color ink;

  /// Secondary text — cues, the step label.
  final Color stepFg;

  /// The stage's own accent: the tap dot, filled slots, the current step dot.
  final Color accent;

  LinearGradient get field => LinearGradient(
    // 172° in CSS terms — very nearly top-to-bottom, tipped slightly.
    begin: const Alignment(-0.14, -1),
    end: const Alignment(0.14, 1),
    colors: [fieldTop, fieldBottom],
  );
}
