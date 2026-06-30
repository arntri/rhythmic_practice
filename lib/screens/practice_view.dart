import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../metronome/metronome_engine.dart';
import '../metronome/metronome_ring.dart';
import '../practice/practice_controller.dart';
import '../practice/progression.dart';
import '../theme.dart';
import '../widgets/slide_to_unlock.dart';

/// Width of the right-edge caregiver verdict bar (also reserved on the right of
/// the centre prompt so the two never overlap).
const double _kCaregiverBarWidth = 150;

/// Per-stage (rung) background tint for read-free stage recognition. Every tint
/// is light + low-saturation (a pale wash, never bright or high-contrast): the
/// word/picture sits on its own near-white patch so it stays equally readable on
/// all of them, and the full-screen beat pulse reads as a gentle swell on top.
/// Stages cross-fade between these (see the [AnimatedContainer] in the layouts).
Color stageColor(Rung rung) => switch (rung) {
      Rung.r0 => const Color(0xFFE7F0FA), // pale blue — receive the beat
      Rung.r1 => const Color(0xFFE3F1EC), // pale aqua — hum to the beat
      Rung.r2 => const Color(0xFFE9F3E3), // pale green — say it together
      Rung.r3 => const Color(0xFFEFF2DA), // pale sage — together, model fades
      Rung.r4 => const Color(0xFFF6EFD9), // warm cream — repeat after
      Rung.r5 => const Color(0xFFF7E9DD), // soft peach — delayed repeat
      Rung.r6 => const Color(0xFFEDE7F6), // gentle lavender — say it on your own
    };

/// A distinct symbol per stage, paired with [stageColor] so colour is never the
/// only cue (ear = listen, speak = say-together, single dot = your turn, …).
IconData stageIcon(Rung rung) => switch (rung) {
      Rung.r0 => Icons.hearing, // ear — receive/listen
      Rung.r1 => Icons.graphic_eq, // waveform — hum/voice
      Rung.r2 => Icons.record_voice_over, // say it together
      Rung.r3 => Icons.volume_down, // the model fades out
      Rung.r4 => Icons.repeat, // repeat after
      Rung.r5 => Icons.timer, // delayed repeat
      Rung.r6 => Icons.fiber_manual_record, // single dot — your turn
    };

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
    this.repsPerBlock = 1,
    this.onCaregiverUnlock,
  });

  final MetronomeEngine engine;
  final PracticeController controller;
  final Map<int, String> phraseText;

  /// Opens the caregiver area from the in-session slide-to-unlock cog shown in
  /// the element-free R0/R1 layout (the right-edge verdict dock is hidden there,
  /// so this is the caregiver's only escape hatch out of the tap sandbox). Null
  /// in widget tests / when no caregiver entry is wired — the cog isn't drawn.
  final VoidCallback? onCaregiverUnlock;

  /// How many consecutive reps make up one word's practice block (therapy §4).
  /// Drives the "Round n of 3" indicator and the word counter. 1 = no blocks.
  final int repsPerBlock;

  /// Decrypted target photos by phrase id (therapy addendum §6). Empty for a
  /// text-only session; when a phrase has one it's shown per [targetDisplay].
  final Map<int, Uint8List> photoByPhrase;

  /// How the target's visual is shown (audio is always the primary cue).
  final TargetDisplay targetDisplay;

  void _onTap() {
    // Score the tap by how close it landed to the beat (current phase).
    controller.registerTap(engine.phase.value);
  }

  @override
  Widget build(BuildContext context) {
    // The base layer is one big tap target (brief §3 State_1) — no small
    // buttons for the user.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _onTap(),
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

    // A word runs several consecutive reps (r0 = 1 window; r1–r6 = 3-rep block),
    // so the top-left counter shows the WORD position (by consecutive group), not
    // the rep. The corner chip shows the current STAGE (which rung we're on).
    final wordIndex = controller.currentWordIndex;
    final wordCount = controller.wordCount;

    // R0 (receive the beat) and R1's hum window are pure exposure — no word, no
    // photo — so they get a streamlined, element-free layout: the whole landscape
    // canvas is a tap sandbox with the pulse ring as the only target (support must
    // never read as "a word/test thrown at me"). This covers preparation /
    // referencePrompt; r1 then leaves it for the caregiver verdict (systemTransition
    // → the normal layout with the dock), while r0 auto-promotes and is never judged.
    final rung = controller.currentRung;
    final elementFree = (rung == Rung.r0 || rung == Rung.r1) &&
        (state == PracticeState.preparation ||
            state == PracticeState.referencePrompt);
    if (elementFree) {
      return _buildElementFree(context, state, rung, wordIndex + 1, wordCount);
    }
    final inPractice = state == PracticeState.referencePrompt ||
        state == PracticeState.inputCapture ||
        state == PracticeState.systemTransition;
    final pillText = switch (state) {
      PracticeState.preparation => 'Find the beat',
      PracticeState.sessionComplete => 'Done',
      _ => 'Word ${wordIndex + 1} of $wordCount',
    };

    return AnimatedContainer(
      // A clear green glow signals the mic is live (State_3); otherwise the
      // stage's own pale tint. The animation cross-fades the tint as the rung
      // changes between stages (smooth, never a hard cut).
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOut,
      color: capturing
          ? const Color(0xFF22C55E).withValues(alpha: 0.30)
          : stageColor(rung),
      child: Stack(
        children: [
          Positioned.fill(
            child: MetronomeRing(phase: engine.phase, enabled: engine.visualEnabled),
          ),
          Positioned.fill(child: Center(child: _centerContent(context, state, phrase))),
          // Word position, top-left.
          Positioned(top: 16, left: 16, child: _InfoPill(text: pillText)),
          // Which STAGE of the ladder we're on — small corner indicator.
          if (inPractice)
            Positioned(
              bottom: 16,
              left: 16,
              child: _StageIndicator(rung: controller.currentRung),
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
          // leaving the left of the screen free for the user to tap.
          if (state == PracticeState.systemTransition)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              child: _caregiverDock(context),
            ),
        ],
      ),
    );
  }

  // --- Element-free R0/R1 layout (brief §1–3) -------------------------------
  // A deep forest-green tap sandbox + an oversized neon-mint concentric pulse
  // ring as the sole target. No word, no photo, no caregiver dock. It's a
  // stateful widget because the beat pulse (+15% on the beat, 70 ms decay) and
  // the R0 lock flash are ephemeral animations this dumb StatelessView can't hold.
  Widget _buildElementFree(
    BuildContext context,
    PracticeState state,
    Rung rung,
    int wordPos,
    int wordCount,
  ) {
    return _ElementFreeArena(
      engine: engine,
      state: state,
      rung: rung,
      pillText: 'Word $wordPos of $wordCount',
      onCaregiverUnlock: onCaregiverUnlock,
    );
  }

  // The "when to speak" cue shown above the word for the speaking rungs. Null
  // means no cue line (it never reaches here for r0/r1, which show their own cue).
  String? _speakCue(PracticeState state, Rung rung) {
    if (state == PracticeState.inputCapture) return 'Now you say it';
    // referencePrompt:
    if (rung == Rung.r3) return 'Carry it as it fades'; // unison-fade
    if (rung == Rung.r2) return 'Say it together'; // full unison
    if (rung == Rung.r4 || rung == Rung.r5) return 'Listen…'; // model plays
    if (rung == Rung.r6) return 'Get ready…'; // solo, mic about to open
    return null;
  }

  Widget _centerContent(BuildContext context, PracticeState state, String phrase) {
    switch (state) {
      case PracticeState.preparation:
        return Text(
          'Tap the beat\n(${controller.inTimeTaps}/${controller.tapsToAdvance})',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w600),
        );
      case PracticeState.referencePrompt:
      case PracticeState.inputCapture:
        // The lowest rungs aren't about the word yet — show the activity, not the
        // text, so the user isn't pushed to read/speak before they're meant to
        // (therapy addendum §4: r0 receive the beat, r1 hum). r2+ show the word.
        switch (controller.currentRung) {
          case Rung.r0:
            return _rungCue(context,
                icon: Icons.music_note,
                title: 'Feel the beat',
                subtitle: 'Tap along if you like — no need to speak.');
          case Rung.r1:
            return _rungCue(context,
                icon: Icons.graphic_eq,
                title: 'Hum along',
                subtitle: 'Hum to the beat — sound, not words yet.');
          default:
            // r2+: a clear step cue ("Listen" / "Say it together" / "Now you
            // say it") above the visual target. Audio is always the primary cue;
            // the VISUAL follows [targetDisplay] — picture-led by default, the
            // written word optional — and we never pile all of them on.
            final cue = _speakCue(state, controller.currentRung);
            final photo = photoByPhrase[controller.currentPhraseId];
            final showPhoto = photo != null && targetDisplay != TargetDisplay.word;
            // Word shows for word/both, or as a fallback when picture-only has no
            // picture to show.
            final showWord = targetDisplay == TargetDisplay.word ||
                targetDisplay == TargetDisplay.both ||
                (targetDisplay == TargetDisplay.picture && !showPhoto);
            // The photo gets less height when the word shares the patch ("both"),
            // so the two fit without forcing the word smaller.
            final bothShown = showPhoto && showWord;
            // The word/picture live on a stable near-white patch so they stay
            // high-contrast on every (tinted) stage background.
            final patch = Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (cue != null) ...[
                    Text(
                      cue,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: AppColors.accent),
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (showPhoto)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height *
                            (bothShown ? 0.34 : 0.5),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.memory(photo, fit: BoxFit.contain),
                      ),
                    ),
                  if (bothShown) const SizedBox(height: 14),
                  if (showWord)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        phrase,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 96, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            );
            // Centre the patch, but if it's taller than the viewport (e.g. a tall
            // photo + word in landscape) let it scroll instead of overflowing.
            return LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(child: patch),
                ),
              ),
            );
        }
      case PracticeState.systemTransition:
        // The verdict prompt reflects what was just done. The word is shown only
        // for the speaking rungs (r2+); for feel-the-beat / hum there was no
        // word, so showing one here would read as "a word thrown at me".
        // The verdict question makes the bar explicit, getting stricter as support
        // drops: r1 participation → r2 unison → r3 fade → r4–r6 solo. (r0 is never
        // judged — it auto-promotes — so it never reaches this state.)
        final rung = controller.currentRung;
        final question = switch (rung) {
          Rung.r1 => 'Did they try to hum or voice along?',
          Rung.r2 => 'Did they say the word with the app?',
          Rung.r3 => 'Did they carry it as the model faded?',
          Rung.r4 => 'Did they say it back on their own?',
          Rung.r5 => 'Did they say it on their own after the pause?',
          Rung.r6 => 'Did they say it independently?',
          _ => 'How was that?',
        };
        return Padding(
          padding: const EdgeInsets.only(right: _kCaregiverBarWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (rung.expectsWord) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      phrase,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 56,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(question,
                  style: const TextStyle(
                      fontSize: 30, fontWeight: FontWeight.w700)),
            ],
          ),
        );
      case PracticeState.sessionComplete:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Session complete',
                style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Done'),
            ),
          ],
        );
    }
  }

  // The caregiver's verdict control: a vertical bar on the right edge, split
  // into three full-height choices. The stored evaluation_label is
  // 0 = Fail, 1 = Pass, 2 = Unsure.
  // A large, friendly cue for the no-word rungs (r0 beat, r1 hum) — an icon, a
  // short instruction, and a calmer subtitle.
  Widget _rungCue(BuildContext context,
      {required IconData icon,
      required String title,
      required String subtitle}) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 76, color: muted),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 56, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, color: muted),
          ),
        ],
      ),
    );
  }

  Widget _caregiverDock(BuildContext context) {
    return SafeArea(
      left: false,
      child: SizedBox(
        width: _kCaregiverBarWidth,
        height: double.infinity,
        child: Column(
          children: [
            Expanded(
              child: _verdictButton(
                label: 'Accept',
                icon: Icons.check_rounded,
                value: 1, // Pass
                color: const Color(0xFF22C55E), // bright green
              ),
            ),
            Expanded(
              child: _verdictButton(
                label: 'Unsure',
                icon: Icons.help_outline_rounded,
                value: 2, // Unsure
                color: const Color(0xFF3B82F6), // blue
              ),
            ),
            Expanded(
              child: _verdictButton(
                label: 'Not yet',
                icon: Icons.replay_rounded,
                value: 0, // Fail
                color: const Color(0xFFFACC15), // yellow
                foreground: const Color(0xFF3A2E00), // dark text for contrast on yellow
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _verdictButton({
    required String label,
    required IconData icon,
    required int value,
    required Color color,
    Color foreground = Colors.white,
  }) {
    return Material(
      color: color,
      child: InkWell(
        onTap: () => controller.setEvaluation(value),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: foreground, size: 36),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: foreground,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
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

/// The element-free R0/R1 arena (brief §1–3): a deep forest-green full-screen tap
/// sandbox with an oversized neon-mint concentric pulse ring as the sole target.
/// Stateful so it can own two ephemeral animations the dumb [PracticeView] can't:
///  • Visual pacing pulse — the rings snap out 15% exactly on the beat, then
///    contract back to base within a 70 ms window (mirroring the haptic).
///  • R0 lock flash — a 200 ms full-opacity burst when the user locks the beat
///    (the 3-in-time-tap move from preparation → reference prompt).
/// R1 voicing glow shifts the canvas to emerald during R1's hum window.
class _ElementFreeArena extends StatefulWidget {
  const _ElementFreeArena({
    required this.engine,
    required this.state,
    required this.rung,
    required this.pillText,
    required this.onCaregiverUnlock,
  });

  final MetronomeEngine engine;
  final PracticeState state;
  final Rung rung;
  final String pillText;
  final VoidCallback? onCaregiverUnlock;

  @override
  State<_ElementFreeArena> createState() => _ElementFreeArenaState();
}

class _ElementFreeArenaState extends State<_ElementFreeArena>
    with TickerProviderStateMixin {
  // The R0/R1 canvas uses the same per-stage pale tint as the rest of the ladder
  // (read-free recognition; calm, never the old high-contrast neon-on-dark). R1
  // deepens its tint a touch while voicing to invite sound.
  Color get _base => stageColor(widget.rung);
  Color get _voicing => Color.alphaBlend(
      AppColors.accent.withValues(alpha: 0.12), stageColor(widget.rung));
  // The ring colour distinguishes the two no-word stages: deep lavender to
  // *receive* the beat (R0), calm emerald to *voice* along (R1, "hum along").
  // Both read clearly on their pale (or warmed) canvas.
  Color get _ringColor => widget.rung == Rung.r1
      ? const Color(0xFF2F8F6B) // emerald — make a sound
      : AppColors.accent; // lavender — receive the beat
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
    // R0 lock flash: 3 in-time taps just moved preparation → reference prompt,
    // i.e. the user locked onto the beat. Burst to signal entrainment is locked.
    if (widget.rung == Rung.r0 &&
        old.state == PracticeState.preparation &&
        widget.state == PracticeState.referencePrompt) {
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
    // R1 voicing glow: R1 never opens the mic (co-production), so its reference
    // prompt IS the sound-production window — warm the canvas to invite voice.
    final voicing =
        widget.rung == Rung.r1 && widget.state == PracticeState.referencePrompt;
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
          // Layer 3 — footer stage chip + 7-dot ladder vector, bottom-left.
          Positioned(
              bottom: 16, left: 16, child: _StageIndicator(rung: widget.rung)),
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
  // rung so R0 and R1 are unmistakable: R0 invites listening/tapping, R1 invites
  // voicing. An activity label (not a word to read), in keeping with the no-test
  // intent of this arena.
  Widget _cueFor(BuildContext context) {
    final (IconData icon, String title, String subtitle) =
        widget.rung == Rung.r1
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

/// A small corner indicator of which STAGE of the MIT ladder we're on — the rung
/// code + its title (e.g. "R2 · Say it together"), with seven dots showing the
/// ladder R0→R6 and the current rung filled in accent.
class _StageIndicator extends StatelessWidget {
  const _StageIndicator({required this.rung});

  final Rung rung;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The stage's own symbol — the read-free cue paired with its colour.
          Icon(stageIcon(rung), size: 16, color: AppColors.accent),
          const SizedBox(width: 7),
          Text('${rung.code} · ${rung.title}',
              style: const TextStyle(
                  fontWeight: FontWeight.w600, color: AppColors.onCalm)),
          const SizedBox(width: 10),
          for (final r in Rung.values)
            Padding(
              padding: const EdgeInsets.only(left: 3),
              child: Icon(
                r == rung ? Icons.circle : Icons.circle_outlined,
                size: 9,
                color: r == rung
                    ? AppColors.accent
                    : AppColors.onCalm.withValues(alpha: 0.35),
              ),
            ),
        ],
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
