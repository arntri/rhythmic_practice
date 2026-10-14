import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/orientation.dart';
import '../data/practice_repository.dart';
import '../widgets/plant.dart';
import '../widgets/vine_slide_control.dart';
import 'caregiver_panel.dart';
import 'first_run_screen.dart';
import 'practice_screen.dart';

/// The patient's home: a green world with a plant in it, and one instruction.
///
/// **The whole screen is the button.** There is no menu, no grid of options, no
/// small target to find. Someone with non-fluent aphasia and possibly a weak
/// right hand taps anywhere at all and practice begins. Everything the caregiver
/// needs is behind a deliberate drag in the corner, where it cannot be opened by
/// accident.
///
/// **The plant is the only progress the patient ever sees.** It grows once for
/// each day practice happens, it is cumulative, and it never goes backwards —
/// see [Plant]. Every rate, percentage and verdict lives behind the slide
/// control.
///
/// The tap opens a short ritual rather than jumping straight into an exercise:
/// a ripple where the finger landed, rain over the plant, the plant growing, a
/// small shake, and then practice. Roughly three seconds. That is deliberate —
/// it marks the beginning of something, and it gives a person time to arrive.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.repository});

  final PracticeRepository? repository;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Where the opening ritual has got to.
enum _Phase { idle, watering, growing, celebrating, starting }

class _HomeScreenState extends State<HomeScreen> {
  late final PracticeRepository _repo = widget.repository ?? PracticeRepository();

  int _stage = 0;
  _Phase _phase = _Phase.idle;
  Offset? _touch;
  String? _profileId;
  final List<Timer> _timers = [];

  /// The design's own timings, in order.
  static const _rain = Duration(milliseconds: 1500);
  static const _shake = Duration(milliseconds: 2350);
  static const _begin = Duration(milliseconds: 3050);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final profile = await _repo.getProfile();
      if (!mounted) return;
      setState(() {
        _profileId = profile.profileId;
        _stage = profile.plantStage;
      });
      if (!profile.onboardingSeen && mounted) {
        await Navigator.of(context).push(
          PortraitPageRoute<void>(
            builder: (_) => FirstRunScreen(repository: _repo),
          ),
        );
        if (mounted) _load();
      }
    } catch (_) {
      // A home screen that fails to load a profile still has to let someone in.
    }
  }

  void _after(Duration d, VoidCallback fn) =>
      _timers.add(Timer(d, () => mounted ? fn() : null));

  Future<void> _tap(TapDownDetails details) async {
    if (_phase != _Phase.idle) return;
    setState(() {
      _touch = details.localPosition;
      _phase = _Phase.watering;
    });

    // The plant grows once per day, and it grows because someone turned up —
    // not because of anything that happens in the session that follows.
    final id = _profileId;
    final grown = id == null ? _stage : await _repo.growPlant(id);
    if (!mounted) return;

    _after(_rain, () => setState(() {
      _stage = grown;
      _phase = _Phase.growing;
    }));
    _after(_shake, () => setState(() => _phase = _Phase.celebrating));
    _after(_begin, () {
      setState(() => _phase = _Phase.starting);
      _openPractice();
    });
  }

  Future<void> _openPractice() async {
    await Navigator.of(context).push(
      LandscapePageRoute<void>(builder: (_) => const PracticeScreen()),
    );
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _touch = null;
    });
    _load(); // the plant may have grown while they were in there
  }

  Future<void> _openCaregiver() async {
    await Navigator.of(context).push(
      PortraitPageRoute<void>(builder: (_) => CaregiverPanel(repository: _repo)),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _phase != _Phase.idle;
    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: busy ? null : _tap,
        child: DecoratedBox(
          // The green world. A single radial wash, brightest behind the plant.
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, 0.04),
              radius: 0.86,
              colors: [
                Color(0xFFE9FDC0),
                Color(0xFFC9F293),
                Color(0xFFA4E578),
                Color(0xFF7ECD5F),
                Color(0xFF5FB650),
              ],
              stops: [0, 0.20, 0.40, 0.68, 1],
            ),
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              // The design is drawn at 844 × 390; scale it to whatever the
              // device gives us so the proportions survive.
              final scale = (box.maxHeight / 390).clamp(0.6, 3.0);
              return Stack(
                children: [
                  if (_touch != null && _phase == _Phase.watering)
                    _Ripple(at: _touch!),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 26 * scale,
                    height: 280 * scale,
                    child: _GrowingPlant(stage: _stage, phase: _phase),
                  ),
                  if (_phase == _Phase.watering)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 20 * scale,
                      height: 280 * scale,
                      child: _Rain(scale: scale),
                    ),
                  // The invite, and then what is happening instead.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 30 * scale,
                    child: AnimatedOpacity(
                      opacity: _phase == _Phase.starting ? 0 : 1,
                      duration: const Duration(milliseconds: 400),
                      child: Text(
                        _phase == _Phase.idle
                            ? 'Tap anywhere to start'
                            : 'Watering',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 30 * scale.clamp(0.8, 1.4),
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.3,
                          color: const Color(0xFF1E4A1B),
                        ),
                      ),
                    ),
                  ),
                  if (_phase == _Phase.starting)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 34 * scale,
                      child: const Center(child: _StartingCard()),
                    ),
                  // The caregiver's corner. A drag, never a tap.
                  Positioned(
                    top: 18 * scale,
                    right: 20 * scale,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        VineSlideControl(onUnlocked: _openCaregiver),
                        const SizedBox(height: 10),
                        Text(
                          'FOR THE CAREGIVER',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.25,
                            color: const Color(0xFF1E4A1B).withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The plant, with the two celebrations the ritual gives it: a pop as it grows,
/// then a small shake. Both are brief — the plant is pleased, not performing.
class _GrowingPlant extends StatelessWidget {
  const _GrowingPlant({required this.stage, required this.phase});

  final int stage;
  final _Phase phase;

  @override
  Widget build(BuildContext context) {
    final growing = phase == _Phase.growing;
    final shaking = phase == _Phase.celebrating;
    return Center(
      child: TweenAnimationBuilder<double>(
        // A new tween each time the phase changes, so the animation replays
        // rather than holding at its end value.
        key: ValueKey(phase),
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: growing ? 850 : (shaking ? 700 : 1)),
        curve: Curves.easeOut,
        builder: (context, t, child) {
          // Grow: a single overshooting pop. Shake: a damped wobble about the
          // pot, which is where a plant would actually pivot.
          final pop = growing ? 1 + 0.085 * math.sin(t * math.pi) : 1.0;
          final tilt = shaking
              ? (1 - t) * 0.063 * math.sin(t * math.pi * 3.4)
              : 0.0;
          return Transform.rotate(
            angle: tilt,
            alignment: Alignment.bottomCenter,
            child: Transform.scale(
              scale: pop,
              alignment: Alignment.bottomCenter,
              child: child,
            ),
          );
        },
        child: Plant(stage: stage),
      ),
    );
  }
}

/// Rain over the plant while it is being watered.
class _Rain extends StatefulWidget {
  const _Rain({required this.scale});

  final double scale;

  @override
  State<_Rain> createState() => _RainState();
}

class _RainState extends State<_Rain> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  /// (x offset within the band, length, opacity, phase offset)
  static const _drops = [
    (14.0, 22.0, 0.85, 0.00),
    (52.0, 26.0, 0.75, 0.18),
    (88.0, 20.0, 0.80, 0.42),
    (126.0, 24.0, 0.90, 0.08),
    (162.0, 18.0, 0.70, 0.55),
    (198.0, 25.0, 0.85, 0.30),
    (236.0, 21.0, 0.75, 0.62),
    (270.0, 23.0, 0.80, 0.24),
    (34.0, 19.0, 0.65, 0.70),
    (108.0, 22.0, 0.70, 0.86),
    (180.0, 20.0, 0.72, 0.94),
    (252.0, 18.0, 0.68, 0.46),
  ];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.scale;
    return IgnorePointer(
      child: Center(
        child: SizedBox(
          width: 300 * s,
          height: 280 * s,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => Stack(
              children: [
                for (final (x, len, alpha, offset) in _drops)
                  _drop(x * s, len * s, alpha, offset, s),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _drop(double x, double len, double alpha, double offset, double s) {
    final t = (_c.value + offset) % 1.0;
    // Fades in at the top and out at the bottom, so drops appear and vanish
    // rather than popping on and off at the edges of the band.
    final fade = t < 0.12
        ? t / 0.12
        : t > 0.88
        ? (1 - t) / 0.12
        : 1.0;
    return Positioned(
      left: x,
      top: -60 * s + t * 270 * s,
      child: Opacity(
        opacity: (alpha * fade).clamp(0.0, 1.0),
        child: Container(
          width: 5 * s,
          height: len,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(3 * s),
          ),
        ),
      ),
    );
  }
}

/// The ripple from where the finger landed. It starts small and at the touch
/// point, so the screen answers the person rather than the centre.
class _Ripple extends StatelessWidget {
  const _Ripple({required this.at});

  final Offset at;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1100),
      curve: Curves.easeOut,
      builder: (context, t, _) {
        const size = 520.0;
        final scale = 0.25 + t * 1.65;
        return Positioned(
          left: at.dx - size / 2,
          top: at.dy - size / 2,
          child: Opacity(
            opacity: (0.55 * (1 - t)).clamp(0.0, 1.0),
            child: Transform.scale(
              scale: scale,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0.5),
                      Colors.white.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.7],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// The card that hands over to the session. Three beats and four words — it is
/// a door, not a screen.
class _StartingCard extends StatelessWidget {
  const _StartingCard();

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 500),
    curve: Curves.easeOut,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, 16 * (1 - t)), child: child),
    ),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 20),
      decoration: BoxDecoration(
        color: const Color(0xFFFBFFF2),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF184614).withValues(alpha: 0.2),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          _Beat(Color(0xFF3E9A3A)),
          SizedBox(width: 9),
          _Beat(Color(0xFF7ACB5C)),
          SizedBox(width: 9),
          _Beat(Color(0xFFBBE49B)),
          SizedBox(width: 20),
          Text(
            "Let's sing together",
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1E4A1B),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Beat extends StatelessWidget {
  const _Beat(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 14,
    height: 14,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
