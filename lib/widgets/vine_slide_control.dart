import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The caregiver's way out of the patient's screen: a bud carried along a vine.
///
/// A drag, never a tap — that is the whole point of it. The home screen is one
/// enormous tap target, so anything tappable near it would be opened by accident
/// by the person the app is for. The gesture has to be deliberate.
///
/// **It completes at halfway.** Release past the middle and the flower opens and
/// it counts; release short of it and the bud travels home. A control that
/// demanded the full width would be a dexterity test placed in front of the one
/// person in the room most likely to fail it — and the caregiver's own hands are
/// often full.
class VineSlideControl extends StatefulWidget {
  const VineSlideControl({
    super.key,
    required this.onUnlocked,
    this.width = 268,
    this.height = 66,
  });

  final VoidCallback onUnlocked;
  final double width;
  final double height;

  /// How far the bud must have travelled, on release, to count.
  static const double completeAt = 0.5;

  @override
  State<VineSlideControl> createState() => _VineSlideControlState();
}

class _VineSlideControlState extends State<VineSlideControl> {
  double _p = 0;
  bool _dragging = false;
  double _startX = 0;
  double _startP = 0;

  double get _knob => widget.height - 14;
  double get _travel => widget.width - _knob - 12;

  void _onDown(DragStartDetails d) {
    _dragging = true;
    _startX = d.localPosition.dx;
    _startP = _p;
  }

  void _onUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    setState(
      () => _p = (_startP + (d.localPosition.dx - _startX) / _travel).clamp(
        0.0,
        1.0,
      ),
    );
  }

  void _onEnd(DragEndDetails _) {
    if (!_dragging) return;
    _dragging = false;
    if (_p >= VineSlideControl.completeAt) {
      // Run to the end and let the flower open before handing over, so the
      // gesture visibly completes rather than the screen changing under it.
      setState(() => _p = 1);
      Future<void>.delayed(const Duration(milliseconds: 420), () {
        if (mounted) widget.onUnlocked();
      });
      Future<void>.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _p = 0);
      });
    } else {
      setState(() => _p = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Horizontal only, and it swallows the drag so the tap-anywhere layer
      // underneath never sees it.
      onHorizontalDragStart: _onDown,
      onHorizontalDragUpdate: _onUpdate,
      onHorizontalDragEnd: _onEnd,
      onHorizontalDragCancel: () => setState(() {
        _dragging = false;
        _p = 0;
      }),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: Stack(
          children: [
            // The vine itself: a translucent track with a few leaves on it.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(widget.height / 2),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.38),
                    width: 1.5,
                  ),
                ),
                child: CustomPaint(painter: _VinePainter()),
              ),
            ),
            // The flower at the far end, opening as the bud approaches it.
            Positioned(
              right: 6,
              top: (widget.height - 42) / 2,
              child: AnimatedOpacity(
                opacity: 0.25 + _p * 0.75,
                duration: const Duration(milliseconds: 220),
                child: AnimatedScale(
                  scale: 0.55 + _p * 0.55,
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutBack,
                  child: const SizedBox(
                    width: 42,
                    height: 42,
                    child: CustomPaint(painter: _FlowerPainter()),
                  ),
                ),
              ),
            ),
            // The bud.
            AnimatedPositioned(
              left: 6 + _p * _travel,
              top: 7,
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 450),
              curve: Curves.easeOutBack,
              child: Container(
                width: _knob,
                height: _knob,
                decoration: BoxDecoration(
                  color: const Color(0xFFFBFFF2),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF184614).withValues(alpha: 0.22),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CustomPaint(painter: _BudPainter()),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The vine the bud travels along, with three small leaves.
class _VinePainter extends CustomPainter {
  static final Path _leaf = Path()
    ..moveTo(0, 0)
    ..cubicTo(8, -11, 30, -11, 40, 0)
    ..cubicTo(30, 11, 8, 11, 0, 0)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 268, sy = size.height / 66;
    canvas.save();
    canvas.scale(sx, sy);

    final vine = Path()
      ..moveTo(20, 40)
      ..quadraticBezierTo(70, 22, 128, 34)
      ..quadraticBezierTo(186, 46, 240, 28);
    canvas.drawPath(
      vine,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );

    const leaves = [
      (74.0, 29.0, -42.0, 0.42),
      (134.0, 38.0, 38.0, 0.42),
      (186.0, 28.0, -40.0, 0.40),
    ];
    for (final (x, y, rot, scale) in leaves) {
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(rot * math.pi / 180);
      canvas.scale(scale);
      canvas.drawPath(
        _leaf,
        Paint()..color = Colors.white.withValues(alpha: 0.6),
      );
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VinePainter oldDelegate) => false;
}

/// The five-petal flower at the end of the vine.
class _FlowerPainter extends CustomPainter {
  const _FlowerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 42;
    canvas.save();
    canvas.scale(s);
    final petal = Paint()..color = const Color(0xFFFFF6CE);
    const centres = [
      (21.0, 10.0),
      (32.0, 18.0),
      (28.0, 31.0),
      (14.0, 31.0),
      (10.0, 18.0),
    ];
    for (final (cx, cy) in centres) {
      canvas.drawCircle(Offset(cx, cy), 8, petal);
    }
    canvas.drawCircle(
      const Offset(21, 21),
      6.5,
      Paint()..color = const Color(0xFFFFD98A),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FlowerPainter oldDelegate) => false;
}

/// The bud on the knob — a leaf-shaped drop with a pale midrib.
class _BudPainter extends CustomPainter {
  const _BudPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 30;
    canvas.save();
    canvas.scale(s);
    final body = Path()
      ..moveTo(15, 27)
      ..cubicTo(15, 27, 5, 21, 5, 13)
      ..cubicTo(5, 7, 10, 3, 15, 3)
      ..cubicTo(20, 3, 25, 7, 25, 13)
      ..cubicTo(25, 21, 15, 27, 15, 27)
      ..close();
    canvas.drawPath(body, Paint()..color = const Color(0xFF6BC254));
    canvas.drawLine(
      const Offset(15, 24),
      const Offset(15, 9),
      Paint()
        ..color = const Color(0xFFFBFFF2)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BudPainter oldDelegate) => false;
}
