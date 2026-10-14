import 'package:flutter/material.dart';

import '../metronome/metronome_engine.dart';
import '../theme.dart';

/// Teaches the caregiver how to tap the patient's hand.
///
/// This is one of MIT's **two active ingredients** — the melody is the other —
/// and until now the app asked for it on every screen of every session while
/// explaining it nowhere. A caregiver was expected to infer a clinical technique
/// from the words "Tap their left hand on each syllable" on a busy screen, in
/// the middle of doing everything else.
///
/// Reachable from first-run and, importantly, **from the caregiver panel at any
/// time** — the first session is the worst moment to learn something and the
/// only moment the old onboarding offered.
///
/// The practice pad at the bottom is the point of the screen. Reading how to tap
/// in time is not the same as having done it once with a beat running.
class TappingTutorialScreen extends StatefulWidget {
  const TappingTutorialScreen({super.key, this.bpm = 60});

  /// The session tempo, so the practice pad feels like the real thing.
  final int bpm;

  @override
  State<TappingTutorialScreen> createState() => _TappingTutorialScreenState();
}

class _TappingTutorialScreenState extends State<TappingTutorialScreen>
    with SingleTickerProviderStateMixin {
  MetronomeEngine? _engine;
  int _taps = 0;

  /// Enough taps to have felt the beat. Not a score and not a gate — the button
  /// out is enabled from the first moment.
  static const _tapsToFeelIt = 8;

  @override
  void dispose() {
    _engine?.dispose();
    super.dispose();
  }

  void _toggleBeat() {
    final engine = _engine;
    if (engine != null) {
      engine.dispose();
      setState(() {
        _engine = null;
        _taps = 0;
      });
      return;
    }
    final next = MetronomeEngine(vsync: this, bpm: widget.bpm)..start();
    setState(() => _engine = next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Tapping their hand')),
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.calmGradient),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                children: [
                  Text(
                    'The tapping is half the therapy',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: AppColors.onCalm,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Melodic intonation therapy works through two things at '
                    'once: the tune, which the app plays, and the rhythm, which '
                    'you tap into their hand. The app cannot do the second one. '
                    'That part is yours.',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: AppColors.onCalm,
                    ),
                  ),
                  const SizedBox(height: 26),

                  _Step(
                    number: 1,
                    title: 'Sit on their left',
                    body:
                        'Rest their LEFT hand palm-down on the table and cover '
                        'it with yours, wrist loose. Left specifically — it is '
                        'the hand this therapy uses, and it is not '
                        'interchangeable with the right.',
                  ),
                  _Step(
                    number: 2,
                    title: 'One tap per syllable',
                    body:
                        'Tap the back of their hand once for each syllable, in '
                        'time with the beat. “Wa-ter” is two taps. “I would like '
                        'to go home now” is seven. Firm enough to feel, not hard.',
                  ),
                  _Step(
                    number: 3,
                    title: 'Keep going while they sing',
                    body:
                        'Tap right through the humming, through the recording, '
                        'and through their own attempt — do not stop when they '
                        'falter. Then rest between phrases: the count-in, the '
                        'long silence before a delayed repeat, and the moment '
                        'you are choosing a verdict all carry no taps. The app '
                        'shows the cue exactly when to tap, so follow that.',
                  ),
                  _Step(
                    number: 4,
                    title: 'It is not a test',
                    body:
                        'Nothing about the tapping is scored, and it cannot hold '
                        'them back or move them on. If their hand is weak, tap '
                        'it for them. If you lose the beat, pick it up again. '
                        'Missing a tap costs nothing.',
                  ),

                  const SizedBox(height: 8),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Try it',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Start the beat and tap the pad below in time. This '
                            'is the same tempo a session runs at.',
                            style: theme.textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 18),
                          _TapPad(
                            engine: _engine,
                            taps: _taps,
                            target: _tapsToFeelIt,
                            onTap: () => setState(() => _taps++),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              FilledButton.tonalIcon(
                                key: const Key('tutorial_beat_toggle'),
                                onPressed: _toggleBeat,
                                icon: Icon(
                                  _engine == null
                                      ? Icons.play_arrow
                                      : Icons.stop,
                                ),
                                label: Text(
                                  _engine == null
                                      ? 'Start the beat'
                                      : 'Stop the beat',
                                ),
                              ),
                              const SizedBox(width: 14),
                              if (_taps >= _tapsToFeelIt)
                                Expanded(
                                  child: Text(
                                    'That is the feel of it.',
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),
                  // Never gated on the practice pad. Someone who already knows
                  // how to do this should not have to perform it to leave.
                  FilledButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      textStyle: const TextStyle(fontSize: 18),
                    ),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.title,
    required this.body,
  });

  final int number;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.onCalm,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: AppColors.onCalm.withValues(alpha: 0.86),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The practice pad: a target that swells on the beat and acknowledges a tap.
///
/// Like the cue in a real session it reports **no accuracy** — an off-beat tap
/// looks the same as an on-beat one. Teaching a caregiver to chase a score here
/// would teach them the wrong thing to do with their attention in a session,
/// where the person, not the pad, is what they should be watching.
class _TapPad extends StatelessWidget {
  const _TapPad({
    required this.engine,
    required this.taps,
    required this.target,
    required this.onTap,
  });

  final MetronomeEngine? engine;
  final int taps;
  final int target;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final running = engine != null;
    return GestureDetector(
      key: const Key('tutorial_tap_pad'),
      behavior: HitTestBehavior.opaque,
      onTapDown: running ? (_) => onTap() : null,
      child: SizedBox(
        height: 150,
        child: engine == null
            ? _pad(context, scale: 1, label: 'Start the beat first')
            : AnimatedBuilder(
                animation: engine!.phase,
                builder: (context, _) {
                  // A swell that peaks on the beat and settles between them, so
                  // there is something to tap WITH rather than a bare timer.
                  final phase = engine!.phase.value;
                  final swell = (1 - phase).clamp(0.0, 1.0);
                  return _pad(
                    context,
                    scale: 1 + 0.12 * swell,
                    label: taps == 0
                        ? 'Tap here on every beat'
                        : '$taps ${taps == 1 ? 'tap' : 'taps'}',
                  );
                },
              ),
      ),
    );
  }

  Widget _pad(BuildContext context, {required double scale, required String label}) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: 190,
          height: 120,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: engine == null
                ? scheme.surfaceContainerHighest
                : AppColors.accent.withValues(alpha: 0.16),
            border: Border.all(
              color: engine == null ? scheme.outlineVariant : AppColors.accent,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: engine == null ? scheme.onSurfaceVariant : AppColors.onCalm,
            ),
          ),
        ),
      ),
    );
  }
}
