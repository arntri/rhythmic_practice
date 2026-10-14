import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../metronome/metronome_engine.dart';
import '../practice/practice_controller.dart';
import 'practice_palette.dart';
import '../practice/mit_sequence.dart';
import '../theme.dart';
import '../widgets/slide_to_unlock.dart';

/// Width of the right-edge caregiver verdict bar (also reserved on the right of
/// the centre prompt so the two never overlap).
const double _kCaregiverBarWidth = 150;

/// Width of the slide-to-unlock control that opens the caregiver panel.
const double _kUnlockWidth = 240;

/// How far down the verdict dock starts, to clear that control.
///
/// The dock is pinned to the right edge and would otherwise run the FULL height,
/// which is exactly where a top-right unlock control wants to sit. Insetting the
/// dock is the resolution: it costs the dock a little height, and it keeps the
/// caregiver's escape hatch reachable **during the verdict** — which is when
/// they are most likely to want it.
const double _kUnlockReserve = 84;

/// The stage tint for [step] — see [PracticePalette], where the whole colour
/// system and the reasoning behind it live.
///
/// Kept as a function here because everything downstream already calls it, but
/// it now returns the design's **field gradient** rather than a flat wash: green
/// for the patient, draining toward a warm neutral as the melody is withdrawn.
StageTint stageTint(MitStep step) => PracticePalette.of(step);

/// The field's flat fallback colour, for places that cannot take a gradient.
Color stageColor(MitStep step) => PracticePalette.of(step).fieldBottom;

/// A distinct symbol per step, paired with the tint so colour is never the only
/// cue (ear = listen, speak = say-together, a question mark = answer, …).
IconData stageIcon(MitStep step) => switch (step) {
  MitStep.humMelody => Icons.hearing, // ear — receive the melody
  MitStep.humUnison => Icons.graphic_eq, // waveform — hum/voice
  MitStep.intoneUnison => Icons.record_voice_over, // say it together
  MitStep.unisonFading => Icons.volume_down, // the model fades out
  MitStep.immediateRepeat => Icons.repeat, // repeat after
  MitStep.delayedRepeat => Icons.timer, // delayed repeat
  MitStep.probeQuestion => Icons.help_outline, // a question to answer
  MitStep.sprechgesang => Icons.music_off, // the tune is deliberately dropped
  MitStep.spokenProduction => Icons.chat_bubble_outline, // ordinary speech
};

/// How much of the phrase staff a given MIT step shows — see
/// [PracticeView._staffModeFor].
enum _StaffMode {
  /// Both of MIT's ingredients: the pitch contour over the beat.
  contoured,

  /// Rhythm only, every slot on one line. Used for a phrase whose tune isn't
  /// known yet — the rhythm is true even when the melody isn't.
  flat,

  /// Nothing. The melody has been withdrawn for good.
  absent,
}

/// The visual layer of a practice session. It is intentionally "dumb": given a
/// running [engine] and a [controller], it just renders whatever the current
/// state is. Keeping it free of database/loading logic means it can be widget-
/// tested by driving the controller directly (no device, no DB).
class PracticeView extends StatelessWidget {
  const PracticeView({
    super.key,
    required this.engine,
    required this.controller,
    required this.phraseText,
    this.photoByPhrase = const {},
    this.targetDisplay = TargetDisplay.both,
    this.onCaregiverUnlock,
    this.syllableCountByPhrase = const {},
    this.stressIndexByPhrase = const {},
    this.humPass = -1,
    this.countdown = 0,
    this.probeQuestionByPhrase = const {},
  });

  final MetronomeEngine engine;
  final PracticeController controller;
  final Map<int, String> phraseText;

  /// Opens the caregiver panel from the in-session slide-to-unlock control,
  /// which sits top-right through the **whole** session — the warm-up arena and
  /// the practice layout alike. Null in widget tests / when no caregiver entry is
  /// wired, in which case the control isn't drawn and the verdict dock reclaims
  /// the full height.
  final VoidCallback? onCaregiverUnlock;

  /// Decrypted target photos by phrase id (therapy addendum §6). Empty for a
  /// text-only session; when a phrase has one it's shown per [targetDisplay].
  final Map<int, Uint8List> photoByPhrase;

  /// Which pass of the per-phrase hum is playing (0-based), or -1 when the hum
  /// isn't running. MIT hums the melody twice before the words; the second pass
  /// is labelled so it reads as "again" rather than as a stutter.
  final int humPass;

  /// How the target's visual is shown (audio is always the primary cue).
  final TargetDisplay targetDisplay;

  /// Per-phrase confirmed syllable count (from the recorded guide's nuclei) and
  /// the caregiver-designated high-note syllable — together they drive the
  /// on-screen **melody cue** (intonation flow, item 9): the high–low contour
  /// shown while the word is presented, so intonation is reinforced visually and
  /// not only through the rhythm. Empty/absent → no cue (e.g. single-syllable or
  /// a phrase whose guide was recorded before contours existed).
  final Map<int, int> syllableCountByPhrase;
  final Map<int, int?> stressIndexByPhrase;

  /// Seconds left in the unison count-in, or 0 when none is running. The banner
  /// is drawn here rather than as an overlay so the staff can dim with it — at
  /// the count-in the contour is about to matter, and does not matter yet.
  final int countdown;

  /// The caregiver's probe question per phrase, for the step that asks it. Absent
  /// or empty falls back to a gentle generic prompt — it never blocks.
  final Map<int, String?> probeQuestionByPhrase;

  void _onTap() {
    // Score the tap by how close it landed to the beat (current phase).
    controller.registerTap(engine.phase.value);
  }

  // Finger-up (or a cancelled tap): record the press dwell for the tap just made
  // (item 16a). A cancelled tap still gets a dwell from its touch-down time so the
  // stream isn't biased toward only the clean taps.
  void _onTapRelease() => controller.registerTapRelease();

  @override
  Widget build(BuildContext context) {
    // The base layer is one big tap target (brief §3 State_1) — no small
    // buttons for the user.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _onTap(),
      // Touch-up / cancel close the tap so its dwell (press duration) is recorded.
      onTapUp: (_) => _onTapRelease(),
      onTapCancel: _onTapRelease,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => _buildForState(context),
      ),
    );
  }

  Widget _buildForState(BuildContext context) {
    final state = controller.state;
    final phrase = phraseText[controller.currentPhraseId] ?? '';
    final capturing = state == PracticeState.inputCapture;

    // The top-left counter shows the item's position in the session; the corner
    // chip shows which MIT step of that item's sequence we're on.
    final wordIndex = controller.currentWordIndex;
    final wordCount = controller.wordCount;

    // Session WARM-UP (once, at the start): tap the beat (preparation) then hum
    // (warmUpHum). It's pure readiness — no word, no photo — so it gets the
    // streamlined, element-free arena: the whole canvas is a tap/hum sandbox with
    // the pulse ring as the only target. The arena reads the tap-vs-hum visuals
    // straight off [state] — the warm-up is not an MIT step, so it has no step
    // to key on. Items never use this layout.
    if (state == PracticeState.preparation ||
        state == PracticeState.warmUpHum) {
      return _ElementFreeArena(
        engine: engine,
        state: state,
        pillText: 'Warm-up',
        onCaregiverUnlock: onCaregiverUnlock,
      );
    }
    final step = controller.currentStep;
    final inPractice =
        state == PracticeState.phraseHum ||
        state == PracticeState.referencePrompt ||
        state == PracticeState.inputCapture ||
        state == PracticeState.systemTransition;
    final pillText = switch (state) {
      PracticeState.sessionComplete => 'Done',
      PracticeState.rest => 'Break',
      PracticeState.paused => 'Paused',
      _ => 'Word ${wordIndex + 1} of $wordCount',
    };

    return AnimatedContainer(
      // A clear green glow signals the mic is live (State_3); otherwise the
      // stage's own pale tint. The animation cross-fades the tint as the run
      // moves between steps (smooth, never a hard cut).
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOut,
      // The field is the patient's whole canvas. While the mic is open a green
      // wash rises from their side of it — the one state change that ignores
      // the stage tint, because it has to mean the same thing at every step.
      decoration: BoxDecoration(
        gradient: stageTint(step).field,
      ),
      foregroundDecoration: capturing
          ? BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.1, 1),
                radius: 1.2,
                colors: [
                  PracticePalette.micWash.withValues(alpha: 0.55),
                  PracticePalette.micWash.withValues(alpha: 0),
                ],
                stops: const [0, 0.66],
              ),
            )
          : null,
      child: Stack(
        children: [
          // The beat pulse: a radial swell from the patient's side of the field
          // plus a pulsing inset edge. It is the ONLY pulse a caregiver with
          // sound and haptics off will ever get, so it is a full-frame gesture
          // rather than a small ring — and it carries no information: it does
          // not change with the step, the verdict, or how the tapping is going.
          //
          // No pulse at all while the caregiver is away: a field still breathing
          // under "Back in a moment" would say the session is running when it is
          // not.
          Positioned.fill(
            child: _BeatPulse(
              phase: engine.phase,
              tint: stageTint(step),
              enabled: engine.visualEnabled && !controller.caregiverAway,
            ),
          ),
          Positioned.fill(
            child: Center(child: _centerContent(context, state, phrase)),
          ),
          // Word position, top-left — with the go badge beside it when this is
          // not the first attempt at the step.
          Positioned(
            top: 16,
            left: 16,
            child: Row(
              children: [
                _InfoPill(text: pillText),
                if (inPractice && _goBadge != null) ...[
                  const SizedBox(width: 12),
                  _goBadge!,
                ],
              ],
            ),
          ),
          // A4 — the count-in, along the bottom, with the word still visible
          // above it. Nothing is being produced yet, so the tap cue is absent
          // and the hand rests.
          if (countdown > 0)
            Positioned(
              left: 24,
              right: _kCaregiverBarWidth,
              bottom: 18,
              child: _CountInBanner(
                seconds: countdown,
                tint: stageTint(step),
              ),
            ),
          // The bottom row: where we are on the left, the tap cue on the right.
          //
          // ONE row, not two independently-positioned widgets. As two, the
          // centred tap cue and the step dots overlapped each other in landscape
          // — visible on the device the first time this ran.
          if (inPractice && countdown == 0)
            Positioned(
              left: 16,
              right: _kCaregiverBarWidth + 8,
              bottom: 14,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    child: _StageIndicator(
                      step: step,
                      sequence: stepsFor(controller.level),
                      tint: stageTint(step),
                    ),
                  ),
                  if (controller.tappingExpected) ...[
                    const SizedBox(width: 16),
                    // Flexible on both sides: on a narrow screen the row has to
                    // give somewhere, and it gives in the text rather than
                    // overflowing.
                    Flexible(
                      child: _TapCue(
                        engine: engine,
                        controller: controller,
                        tint: stageTint(step),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          // Unmistakable "recording" indicator while the mic is live (§ UX).
          if (capturing)
            const Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Center(child: _RecordingPill()),
            ),
          // Caregiver verdict control — a vertical bar pinned to the right edge,
          // leaving the left of the screen free for the user to tap. Its top is
          // inset so the slide-to-unlock below can share the edge.
          if (state == PracticeState.systemTransition)
            Positioned(
              top: onCaregiverUnlock == null ? 0 : _kUnlockReserve,
              bottom: 0,
              right: 0,
              child: _caregiverDock(context),
            ),
          // The caregiver's way out, from ANYWHERE in the session — not just the
          // warm-up, which is all it used to cover. A drag, never a tap: the
          // deliberate gesture is what stops the patient opening the caregiver
          // panel by accident.
          if (onCaregiverUnlock != null)
            Positioned(
              top: 14,
              right: 14,
              child: SizedBox(
                width: _kUnlockWidth,
                child: SlideToUnlock(
                  onUnlocked: onCaregiverUnlock!,
                  label: 'Slide for caregiver',
                ),
              ),
            ),
        ],
      ),
    );
  }

  // The "when to speak" cue shown above the word at each step. Null means no cue
  // line. The warm-up has its own arena and never reaches here.
  String? _speakCue(PracticeState state, MitStep step) {
    if (state == PracticeState.inputCapture) return 'Now you say it';
    // referencePrompt:
    return switch (step) {
      MitStep.unisonFading => 'Carry it as it fades',
      MitStep.intoneUnison => 'Say it together',
      MitStep.humUnison => 'Hum it together',
      // The model plays; at the delayed repeat the silence that follows is the
      // work, so the cue is the same "listen" either way.
      MitStep.immediateRepeat || MitStep.delayedRepeat => 'Listen…',
      MitStep.probeQuestion => 'Answer the question',
      MitStep.sprechgesang => 'Listen — spoken, not sung',
      MitStep.spokenProduction => 'Say it your way',
      MitStep.humMelody => null,
    };
  }

  /// Whether the phrase staff should show a pitch contour at [step], only the
  /// rhythm, or nothing at all.
  ///
  /// This is the therapy's own arc, drawn: the staff carries **both** of MIT's
  /// active ingredients on one row of nodes — vertical position is the melody
  /// (two pitches a minor third apart, exactly what [buildHumMelody] sings) and
  /// horizontal position is the rhythm (one syllable per beat, exactly what the
  /// hand taps). They are the same syllables, so they are one element.
  ///
  /// At the Sprechgesang step the staff **collapses to a single line**: same
  /// nodes, same beat, no pitch — which is precisely what Sprechgesang is. At
  /// spoken production it is gone. The scaffold coming away is the content of
  /// those two steps, and the staff is where it can actually be seen coming away.
  _StaffMode _staffModeFor(MitStep step) => switch (step) {
    // Hidden at BOTH bridge steps, per `Practice Session.dc.html` A10/A11:
    // "Never shows the melody contour. It is the thing being withdrawn." What
    // is left on screen there is the pulse and the tapping, which is the
    // message — the rhythm is still holding you up.
    //
    // NOTE: `Practice Layers.dc.html` 1d says the opposite for these two steps
    // ("the slots settle onto one line"). Session is the later and more
    // specific of the two, so it wins here; flagged rather than picked quietly.
    MitStep.sprechgesang || MitStep.spokenProduction => _StaffMode.absent,
    _ => _StaffMode.contoured,
  };

  // The phrase staff: one node per syllable, the caregiver-designated high-note
  // syllable raised. Returns null when there is nothing to show — a single
  // syllable (nothing to rise above), or [_StaffMode.absent].
  //
  // With a syllable count but no designated stress — a caregiver's own phrase
  // with no authored guide yet — it degrades to the FLAT form rather than
  // vanishing. The rhythm is real information even when the tune isn't known
  // yet: one syllable per beat is what the hand is tapping either way. That also
  // keeps the staff's absence meaningful, rather than ambiguous between "no
  // pitch data" and "the melody has been withdrawn".
  //
  // Per-beat illumination: the node for the syllable sounding right now glows
  // as the beat reaches it. [PracticeController.beatsIntoProduction] is exact
  // rather than a guess from elapsed state-time — the screen opens the
  // production window (`beginProduction`) on the model's REAL start, after any
  // beat-sync wait, so beat 0 of the count really is the first syllable. Only
  // lit while [PracticeController.tappingExpected] — i.e. never while the staff
  // is hidden for capturing anyway, and never during the pre-roll "Get ready"
  // count-in, which is correct: nothing is sounding yet.
  Widget? _phraseStaff(
    BuildContext context, {
    required _StaffMode mode,
    double scale = 1.0,
  }) {
    // ignore: parameter_assignments — the no-tune fallback below downgrades it.
    if (mode == _StaffMode.absent) return null;
    final id = controller.currentPhraseId;
    final count = syllableCountByPhrase[id] ?? 0;
    if (count < 2) return null;
    final rawStress = stressIndexByPhrase[id];
    // A phrase with no designated tune yet — a caregiver's own word with no
    // authored guide — falls back to [_StaffMode.flat]: the rhythm is true even
    // when the melody isn't, and one syllable per beat is what the hand taps
    // either way.
    final hasPitch =
        mode == _StaffMode.contoured &&
        rawStress != null &&
        rawStress >= 0 &&
        rawStress < count;
    if (!hasPitch && mode == _StaffMode.contoured) mode = _StaffMode.flat;
    final activeIndex = controller.tappingExpected
        ? controller.beatsIntoProduction % count
        : null;
    final raise = 12.0 * scale;
    final dot = 16.0 * scale;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      key: const Key('melody_cue'),
      height: 44 * scale,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 5 * scale),
              child: Transform.translate(
                // Flat means flat: every node on one line, still one per beat.
                offset: Offset(
                  0,
                  !hasPitch ? 0 : (i == rawStress ? -raise : raise),
                ),
                child: Container(
                  width: dot,
                  height: dot,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hasPitch && i == rawStress
                        ? scheme.primary
                        : scheme.outlineVariant,
                    boxShadow: i == activeIndex
                        ? [
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.55),
                              blurRadius: 10 * scale,
                              spreadRadius: 2 * scale,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // The hum step (MIT step 1): the phrase's melody, twice, while the item ITSELF
  // is on screen.
  //
  // What this step withholds is the **spoken model** — the clinician hums rather
  // than says the words — not the item's identity. MIT presents the target (in
  // practice, a picture) and then hands over its melody; the person is meant to
  // be holding the phrase in mind against the tune, which they cannot do if they
  // don't yet know which phrase it is. An earlier version of this screen hid the
  // picture too. That was ours, not MIT's, and it also made the back-up into
  // this step read as the app taking the target away at the moment it is
  // supposed to be giving more support.
  //
  // So: the referent is shown exactly as it is at every other step (photo, or
  // the word when there is no photo or the caregiver asked for words), and the
  // melody contour is enlarged, because here the tune is the content rather than
  // a reinforcement.
  Widget _humContent(BuildContext context, String phrase) {
    // The hum is where the tune IS the content, so the staff is enlarged.
    final melody = _phraseStaff(
      context,
      mode: _StaffMode.contoured,
      scale: 2.0,
    );
    final again = humPass >= 1;
    final photo = photoByPhrase[controller.currentPhraseId];
    final showPhoto = photo != null && targetDisplay != TargetDisplay.word;
    return Column(
      key: const Key('phrase_hum'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          again ? 'Again' : 'Listen to the tune',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            color: AppColors.accent,
          ),
        ),
        const SizedBox(height: 20),
        // The item, so there is something for the melody to belong to.
        if (showPhoto)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.34,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.memory(photo, fit: BoxFit.contain),
            ),
          )
        else
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              phrase,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 72, fontWeight: FontWeight.bold),
            ),
          ),
        const SizedBox(height: 20),
        if (melody != null) melody else const Icon(Icons.graphic_eq, size: 88),
        const SizedBox(height: 20),
        const Text(
          'Hum along',
          style: TextStyle(fontSize: 24, color: AppColors.onCalm),
        ),
      ],
    );
  }

  // The break offer, reached from the caregiver's slide-out — **the app never
  // offers it by itself**. The person sitting beside the patient can see
  // whether they are tiring; an app deciding that from item counts gets it
  // wrong in both directions.
  //
  // Both answers are given equal weight on purpose: same size, same distance
  // from the thumb. An offer that is awkward to refuse isn't an offer, it is the
  // app deciding with a politeness on top.
  Widget _restContent(BuildContext context) {
    return Padding(
      key: const Key('rest_offer'),
      padding: const EdgeInsets.only(right: _kCaregiverBarWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_cafe_outlined, size: 56, color: AppColors.accent),
          const SizedBox(height: 18),
          Text(
            'Take a rest?',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              color: AppColors.onCalm,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            controller.itemsFinished == 0
                ? 'We can stop here or keep going.'
                : '${controller.itemsFinished} '
                      '${controller.itemsFinished == 1 ? 'word' : 'words'} done. '
                      'We can stop here or keep going.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 19, color: AppColors.onCalm.withValues(alpha: 0.75)),
          ),
          const SizedBox(height: 30),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              // "Rest now" ends the session for today. Primary only because it
              // is what the caregiver came here to do — not because it is the
              // recommended answer.
              FilledButton(
                key: const Key('rest_stop'),
                onPressed: controller.finishSessionEarly,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 34,
                    vertical: 20,
                  ),
                  textStyle: const TextStyle(fontSize: 21),
                ),
                child: const Text('Rest now'),
              ),
              OutlinedButton(
                key: const Key('rest_carry_on'),
                onPressed: controller.resumeFromRest,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 34,
                    vertical: 20,
                  ),
                  textStyle: const TextStyle(fontSize: 21),
                ),
                child: const Text('Keep going'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // The caregiver is in their panel, or has just come back.
  //
  // While they are away this is a still screen with the beat stopped — nothing
  // should be running while someone reads notes about the person sitting in
  // front of it. When they return the session does NOT start itself: the current
  // step will restart from its beginning, on a tap, because dropping back into
  // the middle of a phrase someone was halfway through singing is worse than
  // starting it again.
  Widget _pausedContent(BuildContext context) {
    final away = controller.caregiverAway;
    return Padding(
      key: const Key('paused'),
      padding: const EdgeInsets.only(right: _kCaregiverBarWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            away ? Icons.pause_circle_outline : Icons.play_circle_outline,
            size: 56,
            color: AppColors.accent,
          ),
          const SizedBox(height: 18),
          Text(
            away ? 'Back in a moment' : 'Ready to carry on',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              color: AppColors.onCalm,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            away ? 'The beat has stopped.' : _resumeCue(),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 19,
              color: AppColors.onCalm.withValues(alpha: 0.75),
            ),
          ),
          if (!away) ...[
            const SizedBox(height: 30),
            FilledButton(
              key: const Key('paused_resume'),
              onPressed: controller.resumeAfterCaregiver,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 34,
                  vertical: 20,
                ),
                textStyle: const TextStyle(fontSize: 21),
              ),
              child: const Text('Start when ready'),
            ),
          ],
        ],
      ),
    );
  }

  // What is about to happen, named — the word and the step it restarts at.
  String _resumeCue() {
    final phrase = phraseText[controller.currentPhraseId] ?? '';
    final step = controller.currentStep.title.toLowerCase();
    return phrase.isEmpty ? step : '$phrase · $step';
  }

  Widget _centerContent(
    BuildContext context,
    PracticeState state,
    String phrase,
  ) {
    switch (state) {
      // Warm-up states render in the element-free arena, never here — but the
      // switch must stay exhaustive.
      case PracticeState.preparation:
      case PracticeState.warmUpHum:
        return const SizedBox.shrink();
      case PracticeState.rest:
        return _restContent(context);
      case PracticeState.paused:
        return _pausedContent(context);
      case PracticeState.phraseHum:
        return _humContent(context, phrase);
      case PracticeState.referencePrompt:
      case PracticeState.inputCapture:
        return _targetPatch(context, phrase, capturing: capturingNow(state));
      case PracticeState.systemTransition:
        // A13 — the verdict hold. The exercise is over and the caregiver's panel
        // has arrived; for the PATIENT the screen simply goes calm. The card
        // stays exactly where it was — the panel slides in over the right side
        // of the field, which was empty anyway, so nothing they are looking at
        // moves — and the contour dims because the phrase is finished.
        //
        // Nothing appears here that could be read as a result. The verdict is a
        // clinical record, not feedback.
        return _targetPatch(context, phrase, dimmed: true);
      case PracticeState.backingUp:
        // A15 — support arriving, in the same sitting. The tint has ALREADY
        // moved backwards along the spectrum (the field is keyed on the step the
        // run is now on), so the wording only has to offer company. No downward
        // arrow, no red, no "eased" or "back to".
        return _messageContent(
          context,
          eyebrow: 'STAYING WITH THIS ONE',
          headline: _backUpHeadline(controller.currentStep),
          sub: controller.currentStep == MitStep.humMelody
              ? 'The tune comes back for a moment'
              : 'We will do the easier one first',
        );
      case PracticeState.itemSetAside:
        // A16 — the item ends for today. The old app spliced in an easier word
        // here to engineer a win; with that gone this moment carries all of the
        // reassurance on its own, which is why it names what is happening and
        // immediately shows what is next.
        final next = controller.nextPhraseId;
        return _messageContent(
          context,
          headline: 'We\u2019ll come back to this one',
          sub: next == null ? null : 'Next: ${phraseText[next] ?? ''}',
        );
      case PracticeState.sessionComplete:
        // A18 — a proper close. It lists what was practised and stops there: no
        // count of passes, no percentage, no comparison with last time. The
        // pulse ends here, and this is the only place in the app it ever does.
        return _messageContent(
          context,
          headline: 'That\u2019s today done',
          sub: controller.itemsFinished == 0
              ? null
              : '${controller.itemsFinished} '
                    '${controller.itemsFinished == 1 ? 'word' : 'words'} '
                    'practised',
          recap: [
            for (var i = 0; i < controller.itemsFinished; i++)
              phraseText[controller.phraseIdAt(i)] ?? '',
          ].where((t) => t.isNotEmpty).toList(),
          action: FilledButton(
            key: const Key('session_done'),
            onPressed: () => Navigator.of(context).maybePop(),
            style: FilledButton.styleFrom(
              backgroundColor: stageTint(controller.currentStep).accent,
              padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 20),
              textStyle: const TextStyle(fontSize: 21),
            ),
            child: const Text('Done'),
          ),
        );
    }
  }

  /// The headline for a back-up, which depends on where they landed. At Level II
  /// the first judged step drops to the hum, and that is worth naming plainly:
  /// the melody is being handed over a second time, not taken away.
  static String _backUpHeadline(MitStep to) => switch (to) {
    MitStep.humMelody => 'Let\u2019s hear the tune again',
    MitStep.humUnison || MitStep.intoneUnison => 'Let\u2019s sing it together again',
    _ => 'Let\u2019s try that with a bit more help',
  };

  /// The shared frame for every moment that is a message rather than an
  /// exercise: backing up, setting aside, the break offer, the end of a session.
  ///
  /// Centred, unhurried, and deliberately plain. None of these is a result, and
  /// none of them should look like one.
  Widget _messageContent(
    BuildContext context, {
    required String headline,
    String? eyebrow,
    String? sub,
    List<String> recap = const [],
    Widget? action,
    Key? key,
  }) {
    final tint = stageTint(controller.currentStep);
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (eyebrow != null) ...[
            Text(
              eyebrow,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.3,
                color: tint.stepFg,
              ),
            ),
            const SizedBox(height: 14),
          ],
          Text(
            headline,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 46,
              height: 1.08,
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
              color: tint.ink,
            ),
          ),
          if (sub != null) ...[
            const SizedBox(height: 14),
            Text(
              sub,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 21,
                height: 1.45,
                fontWeight: FontWeight.w500,
                color: tint.stepFg,
              ),
            ),
          ],
          if (recap.isNotEmpty) ...[
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                for (final word in recap)
                  Container(
                    padding: const EdgeInsets.fromLTRB(18, 13, 18, 13),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      word,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: tint.ink,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (action != null) ...[const SizedBox(height: 26), action],
        ],
      ),
    );
  }

  /// A14 — the second go is routine and barely marked; the third only happens
  /// when the first two left real doubt, so it changes tone rather than getting
  /// sterner. Never the previous verdict, and never "attempt 2 of 3".
  Widget? get _goBadge => switch (controller.repNumber) {
    2 => const _GoBadge(label: 'Again'),
    3 => const _GoBadge(label: 'No rush', caregiverHue: true),
    _ => null,
  };

  /// Whether the mic is open in [state] — the one place the exercise frame
  /// changes without the step changing.
  static bool capturingNow(PracticeState state) =>
      state == PracticeState.inputCapture;

  /// The exercise frame: the cue, the target, and the phrase staff.
  ///
  /// **The same widget renders the verdict hold**, with [dimmed] set. That is
  /// deliberate and it is a design requirement, not a convenience: the panel
  /// slides in over the right side of the field — which was empty anyway — so
  /// nothing the patient is looking at is allowed to move when the exercise
  /// ends. Building the two states from one method is how that stays true.
  Widget _targetPatch(
    BuildContext context,
    String phrase, {
    bool capturing = false,
    bool dimmed = false,
  }) {
    final step = controller.currentStep;
    final tint = stageTint(step);

    // The cue names what is being asked, not how it went.
    final cue = dimmed
        ? null
        : _speakCue(
            capturing ? PracticeState.inputCapture : PracticeState.referencePrompt,
            step,
          );

    // The probe step WITHHOLDS the phrase — showing it would answer the question
    // for them, which collapses this step into a plain repeat.
    final hideTarget = step == MitStep.probeQuestion;
    final photo = photoByPhrase[controller.currentPhraseId];
    final showPhoto =
        !hideTarget && photo != null && targetDisplay != TargetDisplay.word;
    final showWord =
        !hideTarget &&
        (targetDisplay == TargetDisplay.word ||
            targetDisplay == TargetDisplay.both ||
            (targetDisplay == TargetDisplay.picture && !showPhoto));

    final staff = capturing
        ? null // never while they are speaking: it becomes a thing to chase
        : _phraseStaff(context, mode: _staffModeFor(step));

    // How present the staff is. It fades rather than leaving, so the phrase is
    // still there to hold onto: dimmed through the count-in (about to matter,
    // not yet), further through the held silence, and once more at the verdict.
    final staffOpacity = dimmed
        ? 0.5
        : countdown > 0
        ? 0.4
        : step == MitStep.delayedRepeat
        ? 0.3
        : 1.0;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (cue != null) ...[
          Text(
            cue,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.w600,
              color: tint.stepFg,
            ),
          ),
          const SizedBox(height: 18),
        ],
        // A9 — the question, shown AS a question: its own bubble, its own tag,
        // and one square corner so it reads as speech rather than instruction.
        if (hideTarget && !dimmed) ...[
          _QuestionBubble(
            text: probeQuestionByPhrase[controller.currentPhraseId],
            tint: tint,
          ),
          const SizedBox(height: 18),
        ],
        if (showPhoto || showWord)
          Container(
            padding: const EdgeInsets.fromLTRB(18, 16, 26, 16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.86),
              borderRadius: BorderRadius.circular(26),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showPhoto) ...[
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.34,
                      maxWidth: 200,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Image.memory(photo, fit: BoxFit.contain),
                    ),
                  ),
                  if (showWord) const SizedBox(width: 20),
                ],
                if (showWord)
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        phrase,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 52,
                          height: 1.05,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1,
                          color: tint.ink,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (staff != null) ...[
          const SizedBox(height: 18),
          Opacity(opacity: staffOpacity, child: staff),
        ],
        // A6 — the model's presence, running out across the last syllable. It
        // thins and fades rather than stopping, so it reads as the app easing
        // off, never as the audio cutting out.
        if (step == MitStep.unisonFading && !dimmed && !capturing) ...[
          const SizedBox(height: 18),
          Container(
            width: 430,
            height: 8,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: LinearGradient(
                colors: [tint.accent, tint.accent, tint.accent.withValues(alpha: 0)],
                stops: const [0, 0.52, 1],
              ),
            ),
          ),
        ],
        // A8 — six seconds, held. **No timer**: a countdown here becomes a
        // pressure clock. The beat pulse is what tells the caregiver the app has
        // not hung; these two short rules just hold the moment open.
        if (step == MitStep.delayedRepeat && !dimmed && !capturing) ...[
          const SizedBox(height: 24),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _HoldRule(color: tint.stepFg),
              const SizedBox(width: 16),
              Text(
                'Take your time',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: tint.stepFg,
                ),
              ),
              const SizedBox(width: 16),
              _HoldRule(color: tint.stepFg),
            ],
          ),
        ],
      ],
    );

    // Centre it, but let a tall photo scroll rather than overflow.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: content),
        ),
      ),
    );
  }

  // The caregiver's verdict panel.
  //
  // **Not a permanent layer.** While an exercise runs the patient has the whole
  // screen and there is nothing on it about being judged; the panel arrives the
  // moment the exercise ends, over the right side of the field — which was empty
  // anyway, so nothing the patient is looking at moves. Then it leaves again.
  //
  // Green for yes, lavender for maybe, warm sand for not yet: the caregiver's
  // three hues, and **never red**. "Not yet" is where support goes next, not a
  // failure.
  //
  // It appears after every single exercise, so it is deliberately inert — no
  // animation on the choices, no confirmation, nothing to read after tapping.
  // The stored evaluation_label is 0 = Fail, 1 = Pass, 2 = Unsure.
  Widget _caregiverDock(BuildContext context) {
    return SafeArea(
      left: false,
      child: Container(
        width: _kCaregiverBarWidth,
        height: double.infinity,
        margin: const EdgeInsets.fromLTRB(0, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
        decoration: BoxDecoration(
          color: PracticePalette.dockBg.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF281E46).withValues(alpha: 0.10),
              blurRadius: 30,
              offset: const Offset(-14, 0),
            ),
          ],
        ),
        child: Column(
          children: [
            // The question is per step, and it is the caregiver's whole job on
            // this screen — so it sits above the choices rather than beside them.
            Text(
              _verdictQuestion(controller.currentStep),
              style: const TextStyle(
                fontSize: 13.5,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: PracticePalette.lavenderInk,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: _verdictButton(
                      label: 'Yes',
                      icon: Icons.check_rounded,
                      value: 1, // Pass
                      background: PracticePalette.yesBg,
                      border: PracticePalette.yesBd,
                      foreground: PracticePalette.yesFg,
                    ),
                  ),
                  const SizedBox(height: 9),
                  Expanded(
                    child: _verdictButton(
                      label: 'Maybe',
                      icon: Icons.help_outline_rounded,
                      value: 2, // Unsure
                      background: PracticePalette.maybeBg,
                      border: PracticePalette.maybeBd,
                      foreground: PracticePalette.maybeFg,
                    ),
                  ),
                  const SizedBox(height: 9),
                  Expanded(
                    child: _verdictButton(
                      label: 'Not yet',
                      icon: Icons.replay_rounded,
                      value: 0, // Fail
                      background: PracticePalette.notYetBg,
                      border: PracticePalette.notYetBd,
                      foreground: PracticePalette.notYetFg,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The question the caregiver is actually being asked, per step. It gets
  /// stricter as the support drops away: unison → fade → repeat → answer → the
  /// tune coming off.
  static String _verdictQuestion(MitStep step) => switch (step) {
    MitStep.humUnison => 'Did they hum it with you?',
    MitStep.intoneUnison => 'Did they say it with you?',
    MitStep.unisonFading => 'Did they carry it as it faded?',
    MitStep.immediateRepeat => 'Did they say it back?',
    MitStep.delayedRepeat => 'Did they say it after the pause?',
    MitStep.probeQuestion => 'Did they answer with the phrase?',
    MitStep.sprechgesang => 'Did they say it without the tune?',
    MitStep.spokenProduction => 'Did they say it the ordinary way?',
    MitStep.humMelody => 'How was that?',
  };

  Widget _verdictButton({
    required String label,
    required IconData icon,
    required int value,
    required Color background,
    required Color border,
    required Color foreground,
  }) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        onTap: () => controller.setEvaluation(value),
        borderRadius: BorderRadius.circular(15),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: border, width: 2),
          ),
          child: Row(
            children: [
              Icon(icon, color: foreground, size: 22),
              const SizedBox(width: 11),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
/// A calm translucent pill for the activity/position label.
class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: const TextStyle(
              fontWeight: FontWeight.w600, color: AppColors.onCalm)),
    );
  }
}

/// The element-free warm-up arena: a full-screen tap/hum sandbox with an
/// oversized concentric pulse ring as the sole target, used for the once-per-
/// session warm-up (preparation = tap, warmUpHum = hum). Stateful so it can own
/// two ephemeral animations the dumb [PracticeView] can't:
///  • Visual pacing pulse — the rings snap out 15% exactly on the beat, then
///    contract back to base within a 70 ms window (mirroring the haptic).
///  • Lock flash — a 200 ms full-opacity burst when the user locks the beat
///    (the 3-in-time-tap move from preparation → warm-up hum).
/// A voicing glow shifts the canvas to emerald during the hum phase.
class _ElementFreeArena extends StatefulWidget {
  const _ElementFreeArena({
    required this.engine,
    required this.state,
    required this.pillText,
    required this.onCaregiverUnlock,
  });

  final MetronomeEngine engine;
  final PracticeState state;
  final String pillText;
  final VoidCallback? onCaregiverUnlock;

  @override
  State<_ElementFreeArena> createState() => _ElementFreeArenaState();
}

class _ElementFreeArenaState extends State<_ElementFreeArena>
    with TickerProviderStateMixin {
  /// Whether this is the humming half of the warm-up (vs the beat-lock).
  bool get _humming => widget.state == PracticeState.warmUpHum;

  // The warm-up borrows the first two stage tints. It is not an MIT step, so it
  // has no place of its own on the drain — but it is still the patient's field,
  // so it is still green.
  StageTint get _tint =>
      _humming ? PracticePalette.warmUpHum : PracticePalette.warmUpTap;
  Color get _base => _tint.fieldBottom;
  Color get _voicing =>
      Color.alphaBlend(_tint.accent.withValues(alpha: 0.10), _base);
  // The ring is the stage's own accent, and it stays in the patient's green
  // either way — lavender is the caregiver's hue and appears nowhere here.
  Color get _ringColor => _tint.accent;
  static const double _ringSize = 220 * 1.35; // 1.35× the text-active states

  // 70 ms beat pulse: value 1 = resting at base; on the beat it jumps to 0
  // (peak +15%) and decays back to 1 across the window.
  late final AnimationController _pulse;
  // 200 ms lock flash: value sweeps 0→1; opacity = sin(π·value) — a clean burst.
  late final AnimationController _flash;
  double _lastPhase = 0;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 70),
      value: 1, // rest at base size
    );
    _flash =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    widget.engine.phase.addListener(_onPhase);
  }

  // The phase rises 0→1 within each beat then resets — a drop marks the beat
  // landing, so we fire the contract-from-peak pulse exactly then.
  void _onPhase() {
    if (!widget.engine.visualEnabled) return;
    final p = widget.engine.phase.value;
    if (p < _lastPhase) _pulse.forward(from: 0);
    _lastPhase = p;
  }

  @override
  void didUpdateWidget(_ElementFreeArena old) {
    super.didUpdateWidget(old);
    // Lock flash: 3 in-time taps just moved preparation → the warm-up hum, i.e.
    // the user locked onto the beat. Burst to signal entrainment is locked.
    if (old.state == PracticeState.preparation &&
        widget.state == PracticeState.warmUpHum) {
      _flash.forward(from: 0);
    }
  }

  @override
  void dispose() {
    widget.engine.phase.removeListener(_onPhase);
    _pulse.dispose();
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Hum voicing glow: the warm-up hum phase IS the sound-production window —
    // warm the canvas to invite voice.
    final voicing = _humming;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeInOut,
      color: voicing ? _voicing : _base,
      child: Stack(
        children: [
          // Layer 1 — the concentric pulse ring. IgnorePointer so every tap falls
          // through to the global sandbox (the GestureDetector in PracticeView).
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_pulse, _flash]),
                  builder: (context, _) => _buildRing(),
                ),
              ),
            ),
          ),
          // Layer 1b — the stage's activity cue, centred in the ring's hole. It
          // doesn't pulse (sits outside the scale transform), so the ring
          // "breathes" around a steady label. This is the main thing that tells
          // R0 (receive the beat) and R1 (hum along) apart at a glance.
          Positioned.fill(
            child: IgnorePointer(child: Center(child: _cueFor(context))),
          ),
          // Layer 2 — header overlays. Position pill top-left; caregiver cog
          // top-right with its own touch box, isolated from the tap grid.
          Positioned(top: 16, left: 16, child: _InfoPill(text: widget.pillText)),
          if (widget.onCaregiverUnlock != null)
            Positioned(
              top: 16,
              right: 16,
              child: SizedBox(
                width: 260,
                child: SlideToUnlock(
                  onUnlocked: widget.onCaregiverUnlock!,
                  label: 'Slide for caregiver',
                ),
              ),
            ),
          // Layer 3 — footer chip naming the warm-up half we're in. No step
          // dots: the warm-up sits outside MIT's sequence, so there is no
          // position in it to show.
          Positioned(
              bottom: 16, left: 16, child: _WarmUpIndicator(humming: _humming)),
        ],
      ),
    );
  }

  Widget _buildRing() {
    final enabled = widget.engine.visualEnabled;
    // pulse: 1 on the beat → 0 at rest. Scale peaks +15% on the beat.
    final pulse = enabled ? (1 - _pulse.value) : 0.0;
    final scale = 1.0 + 0.15 * pulse;
    final opacity = enabled ? (0.55 + 0.35 * pulse) : 0.15;
    final flash = math.sin(math.pi * _flash.value); // 0 → 1 → 0 burst

    return Transform.scale(
      scale: scale,
      child: SizedBox(
        key: const Key('ef_pulse_ring'),
        width: _ringSize,
        height: _ringSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Outer ring.
            Opacity(opacity: opacity, child: _ringCircle(_ringSize, 14)),
            // Inner concentric ring, a touch fainter, for depth.
            Opacity(
                opacity: opacity * 0.6,
                child: _ringCircle(_ringSize * 0.6, 9)),
            // The lock flash — a bright burst across the rings.
            if (flash > 0.01)
              Opacity(
                opacity: flash,
                child: _ringCircle(_ringSize, 18, color: AppColors.accent),
              ),
          ],
        ),
      ),
    );
  }

  // The no-word stage's activity cue (icon + title + subtitle), differing per
  // half so the two are unmistakable: one invites listening/tapping, the other
  // invites voicing. An activity label (not a word to read), in keeping with the
  // no-test intent of this arena.
  Widget _cueFor(BuildContext context) {
    final (IconData icon, String title, String subtitle) = _humming
        ? (Icons.graphic_eq, 'Hum along', 'Make a sound to the beat')
        : (Icons.hearing, 'Feel the beat', 'Tap along if you like');
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 54, color: _ringColor),
        const SizedBox(height: 10),
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: AppColors.onCalm)),
        const SizedBox(height: 6),
        Text(subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 16, color: AppColors.onCalm.withValues(alpha: 0.7))),
      ],
    );
  }

  Widget _ringCircle(double size, double border, {Color? color}) {
    color ??= _ringColor;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: border),
      ),
    );
  }
}


/// The live-recording indicator shown while the mic is capturing.
class _RecordingPill extends StatelessWidget {
  const _RecordingPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E9E5A),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, color: Colors.white, size: 14),
          SizedBox(width: 8),
          Text('Recording — say it once',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// Where we are in MIT's sequence — the step's title, plus one dot per step of
/// **this level's** sequence with the current one filled.
///
/// The dots are the useful part: every item runs the whole sequence, so this
/// says how far through it we are and how much is left. Three dots at Level I,
/// five at Level II, four at Level III. It is a position in a run, never a rank
/// the phrase holds.
class _StageIndicator extends StatelessWidget {
  const _StageIndicator({
    required this.step,
    required this.sequence,
    required this.tint,
  });

  final MitStep step;
  final List<MitStep> sequence;
  final StageTint tint;

  @override
  Widget build(BuildContext context) {
    final ordinal = sequence.indexOf(step) + 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The title yields before the dots do: the dots ARE the position, and
        // the title mostly repeats the cue already on screen.
        Flexible(
          child: Text(
            ordinal > 0 ? 'Step $ordinal · ${step.title}' : step.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: tint.stepFg,
            ),
          ),
        ),
        const SizedBox(width: 12),
        for (var i = 0; i < sequence.length; i++)
          Padding(
            padding: const EdgeInsets.only(left: 7),
            child: _StepDot(
              current: sequence[i] == step,
              done: i < ordinal - 1,
              tint: tint,
            ),
          ),
      ],
    );
  }
}

class _StepDot extends StatelessWidget {
  const _StepDot({
    required this.current,
    required this.done,
    required this.tint,
  });

  final bool current;
  final bool done;
  final StageTint tint;

  @override
  Widget build(BuildContext context) {
    final size = current ? 13.0 : 9.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: current
            ? tint.accent
            : done
            ? PracticePalette.dotDone
            : Colors.transparent,
        border: current
            ? Border.all(color: tint.ink, width: 2)
            : done
            ? null
            : Border.all(color: PracticePalette.dotFuture, width: 2),
      ),
    );
  }
}

/// The warm-up's own corner chip. Deliberately not a [_StageIndicator]: the
/// warm-up is not one of MIT's steps, so giving it a step number and a place
/// among the dots would misrepresent it as part of the sequence.
class _WarmUpIndicator extends StatelessWidget {
  const _WarmUpIndicator({required this.humming});

  final bool humming;

  @override
  Widget build(BuildContext context) {
    final tint =
        humming ? PracticePalette.warmUpHum : PracticePalette.warmUpTap;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          humming ? Icons.graphic_eq : Icons.hearing,
          size: 16,
          color: tint.accent,
        ),
        const SizedBox(width: 8),
        Text(
          humming ? 'Warm-up · Hum along' : 'Warm-up · Feel the beat',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: tint.stepFg,
          ),
        ),
      ],
    );
  }
}

/// The hand-tapping cue: a dot that swells on the beat, beside the instruction.
///
/// **It reports no accuracy.** A tap landing off the beat looks identical to one
/// landing on it — deliberately, because tapping is a support and never a test,
/// and because a caregiver chasing a score here is watching the screen instead
/// of the person.
///
/// It is **phrase-locked, not clock-locked**: shown only while something is being
/// produced, and absent in the count-in, the six-second held silence and the
/// verdict. MIT's hand rests in the gaps.
class _TapCue extends StatelessWidget {
  const _TapCue({
    required this.engine,
    required this.controller,
    required this.tint,
  });

  final MetronomeEngine engine;
  final PracticeController controller;
  final StageTint tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 17, 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Something to tap WITH, so a caregiver has a pulse to follow even
          // with sound and haptics switched off.
          AnimatedBuilder(
            animation: engine.phase,
            builder: (context, _) {
              final swell = engine.visualEnabled
                  ? (1 - engine.phase.value).clamp(0.0, 1.0)
                  : 0.0;
              return Container(
                width: 20 + 6 * swell,
                height: 20 + 6 * swell,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: tint.accent,
                ),
              );
            },
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              'Tap their left hand on each syllable',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: tint.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A9's question, shown as a question rather than as an instruction: its own tag
/// above it, and one square corner so the shape reads as speech.
///
/// The target phrase is deliberately NOT on screen while this is — showing it
/// would answer the question for them.
class _QuestionBubble extends StatelessWidget {
  const _QuestionBubble({required this.text, required this.tint});

  final String? text;
  final StageTint tint;

  /// What is asked when the caregiver has not set a question for this phrase.
  /// It never blocks the step; it just asks less specifically.
  static const _generic = 'Your turn — what would you say?';

  @override
  Widget build(BuildContext context) {
    final question = (text?.trim().isNotEmpty ?? false) ? text!.trim() : _generic;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: Container(
        padding: const EdgeInsets.fromLTRB(26, 18, 26, 20),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.8),
          border: Border.all(color: tint.edge, width: 2),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(22),
            topRight: Radius.circular(22),
            bottomRight: Radius.circular(22),
            bottomLeft: Radius.circular(6), // the corner that makes it speech
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'A QUESTION FOR YOU',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.95,
                color: tint.accent,
              ),
            ),
            const SizedBox(height: 9),
            Text(
              question,
              style: TextStyle(
                fontSize: 31,
                height: 1.25,
                fontWeight: FontWeight.w700,
                color: tint.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the two short rules that hold the delayed repeat's silence open.
class _HoldRule extends StatelessWidget {
  const _HoldRule({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 56,
    height: 2,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(1),
    ),
  );
}

/// The chip beside the item counter on a second or third go.
///
/// One small chip is the whole difference between the first attempt and the
/// second — the exercise itself is identical, and making the repeat look
/// different would make it feel like a retest.
class _GoBadge extends StatelessWidget {
  const _GoBadge({required this.label, this.caregiverHue = false});

  final String label;

  /// The third go uses the caregiver's lavender rather than the field's green.
  /// It is the one moment the app is speaking to the caregiver mid-exercise —
  /// "we want to be sure", not "you are failing".
  final bool caregiverHue;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
    decoration: BoxDecoration(
      color: caregiverHue
          ? PracticePalette.maybeBg
          : Colors.white.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: caregiverHue
            ? PracticePalette.maybeFg
            : PracticePalette.stages[2].stepFg,
      ),
    ),
  );
}

/// The unison count-in, along the bottom so it never covers the word.
class _CountInBanner extends StatelessWidget {
  const _CountInBanner({required this.seconds, required this.tint});

  final int seconds;
  final StageTint tint;

  @override
  Widget build(BuildContext context) => Container(
    height: 88,
    padding: const EdgeInsets.symmetric(horizontal: 26),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.82),
      borderRadius: BorderRadius.circular(22),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Get ready to say it together',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: tint.ink,
          ),
        ),
        Text(
          '$seconds',
          style: TextStyle(
            fontSize: 52,
            height: 1,
            fontWeight: FontWeight.w800,
            color: tint.accent,
          ),
        ),
      ],
    ),
  );
}

/// The beat pulse: a radial swell from the patient's side of the field, plus an
/// inset edge, both easing between full and almost-nothing across one beat.
///
/// **It never carries information.** It does not change with the step, the
/// verdict, or how well the tapping is going — it is a metronome, and a
/// metronome that started meaning things would be one more thing to read on a
/// screen designed to have very little on it.
///
/// On the drained stages the edge holds its weight by going *darker* rather than
/// greener, since the colour is the thing being deliberately taken away and so
/// cannot be what carries the pulse.
class _BeatPulse extends StatelessWidget {
  const _BeatPulse({
    required this.phase,
    required this.tint,
    required this.enabled,
  });

  final ValueListenable<double> phase;
  final StageTint tint;
  final bool enabled;

  /// Where in the beat the swell bottoms out. Bright ON the beat, faint between,
  /// so the peak lands where a hand should tap rather than halfway between taps.
  static const _trough = 0.55;

  double _opacity(double p) {
    if (p <= _trough) {
      return 1 - (1 - 0.06) * (p / _trough);
    }
    return 0.06 + (1 - 0.06) * ((p - _trough) / (1 - _trough));
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: phase,
        builder: (context, _) {
          final o = _opacity(phase.value.clamp(0.0, 1.0));
          return Stack(
            children: [
              Positioned.fill(
                child: Opacity(
                  opacity: o,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        // Low and slightly left — the patient's side of a
                        // propped phone, where their hands are.
                        center: const Alignment(-0.1, 0.16),
                        radius: 1.3,
                        colors: [tint.glow, tint.glow.withValues(alpha: 0)],
                        stops: const [0, 0.6],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Opacity(
                  opacity: o * 0.34,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: tint.edge, width: 12),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
