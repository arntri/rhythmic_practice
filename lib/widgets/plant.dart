import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The plant on the home screen, in five growth stages.
///
/// **What it means, and what it must never mean.** The plant grows once for each
/// day practice happens, it is cumulative, and it **never goes backwards**. Not
/// on a bad session, not on a missed week, not on a run of "Not yet" verdicts.
/// It is a record of turning up, which is the thing this therapy actually asks
/// of a family — and a plant that could wilt would be a way of telling someone
/// caring for a parent with aphasia that they had failed at it.
///
/// It is also the only progress the *patient* ever sees. Every rate, every
/// percentage and every verdict lives behind the caregiver's slide control.
///
/// Drawn rather than imported: the shapes are a stem, one leaf used many times
/// at different angles, a pot, and some circles, so a painter is smaller and
/// sharper than adding an SVG dependency for it.
class Plant extends StatelessWidget {
  const Plant({super.key, required this.stage});

  /// 0–4, clamped. Higher is more grown.
  final int stage;

  /// The last stage. Reaching it is not an ending — practice carries on, the
  /// plant just stops being the thing that changes.
  static const int maxStage = 4;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _PlantPainter(stage.clamp(0, maxStage)),
    size: Size.infinite,
  );
}

/// One leaf, at a position, angle and size.
class _Leaf {
  const _Leaf(this.x, this.y, this.rotation, this.scale, this.color);
  final double x;
  final double y;

  /// Degrees, matching the source drawing's convention.
  final double rotation;
  final double scale;
  final Color color;
}

/// A stem or branch: a quadratic curve from [x0],[y0] through a control point.
class _Stalk {
  const _Stalk(
    this.x0,
    this.y0,
    this.cx,
    this.cy,
    this.x1,
    this.y1,
    this.width,
  );
  final double x0, y0, cx, cy, x1, y1, width;
}

/// An unopened bud.
class _Bud {
  const _Bud(this.cx, this.cy, this.rx, this.ry);
  final double cx, cy, rx, ry;
}

/// An open flower: a pale disc with a warmer centre.
class _Flower {
  const _Flower(this.cx, this.cy, this.r, this.rInner);
  final double cx, cy, r, rInner;
}

class _Stage {
  const _Stage({
    required this.shadowRx,
    required this.stemColor,
    required this.stalks,
    required this.leaves,
    this.buds = const [],
    this.flowers = const [],
  });

  final double shadowRx;
  final Color stemColor;

  /// The main stem first, then any side branches.
  final List<_Stalk> stalks;
  final List<_Leaf> leaves;
  final List<_Bud> buds;
  final List<_Flower> flowers;
}

const _pot = Color(0xFFE39F70);
const _potRim = Color(0xFFF0B98C);
const _budColor = Color(0xFFDCF2AE);
const _petal = Color(0xFFFFF6CE);
const _pollen = Color(0xFFFFD98A);

/// The five stages, transcribed from the design.
///
/// Each is a whole drawing rather than a diff of the last: the leaves shift and
/// the stem lengthens between stages, so interpolating would produce plants the
/// design never sanctioned.
const List<_Stage> _stages = [
  // 0 — day one. Two leaves, barely out of the soil.
  _Stage(
    shadowRx: 54,
    stemColor: Color(0xFF7CC46A),
    stalks: [_Stalk(100, 170, 99, 157, 100, 146, 5)],
    leaves: [
      _Leaf(100, 154, -34, 0.52, Color(0xFFB7E48C)),
      _Leaf(100, 156, -146, 0.52, Color(0xFF9BD877)),
    ],
  ),
  // 1 — five leaves, a taller stem.
  _Stage(
    shadowRx: 54,
    stemColor: Color(0xFF6BBB5A),
    stalks: [_Stalk(100, 170, 98, 148, 100, 126, 5.5)],
    leaves: [
      _Leaf(100, 159, -35, 0.64, Color(0xFFA9DF84)),
      _Leaf(100, 161, -145, 0.64, Color(0xFF8ED06C)),
      _Leaf(100, 138, -30, 0.70, Color(0xFFA9DF84)),
      _Leaf(100, 140, -150, 0.70, Color(0xFF8ED06C)),
      _Leaf(100, 126, -90, 0.42, Color(0xFFC2E9A0)),
    ],
  ),
  // 2 — seven leaves.
  _Stage(
    shadowRx: 55,
    stemColor: Color(0xFF5EB551),
    stalks: [_Stalk(100, 170, 96, 136, 100, 102, 6)],
    leaves: [
      _Leaf(100, 161, -38, 0.72, Color(0xFF95D974)),
      _Leaf(100, 163, -142, 0.72, Color(0xFF77C95E)),
      _Leaf(99, 140, -32, 0.86, Color(0xFF95D974)),
      _Leaf(99, 142, -148, 0.86, Color(0xFF77C95E)),
      _Leaf(100, 118, -28, 0.74, Color(0xFFA2DE80)),
      _Leaf(100, 120, -152, 0.74, Color(0xFF83CF68)),
      _Leaf(100, 102, -90, 0.46, Color(0xFFBCE79A)),
    ],
  ),
  // 3 — side branches, and the first buds.
  _Stage(
    shadowRx: 56,
    stemColor: Color(0xFF52AE49),
    stalks: [
      _Stalk(100, 170, 95, 126, 100, 80, 6.5),
      _Stalk(99, 126, 117, 119, 127, 104, 4.5),
      _Stalk(99, 108, 82, 101, 72, 88, 4.5),
    ],
    leaves: [
      _Leaf(100, 162, -38, 0.76, Color(0xFF88D267)),
      _Leaf(100, 164, -142, 0.76, Color(0xFF69C455)),
      _Leaf(98, 144, -30, 0.94, Color(0xFF88D267)),
      _Leaf(98, 146, -150, 0.94, Color(0xFF69C455)),
      _Leaf(127, 104, -56, 0.60, Color(0xFF95D974)),
      _Leaf(72, 88, -124, 0.60, Color(0xFF95D974)),
      _Leaf(99, 122, -26, 0.82, Color(0xFF95D974)),
      _Leaf(99, 124, -154, 0.82, Color(0xFF76CB60)),
      _Leaf(100, 98, -24, 0.62, Color(0xFFA6E084)),
      _Leaf(100, 100, -156, 0.62, Color(0xFF87D26A)),
    ],
    buds: [_Bud(100, 74, 7, 9), _Bud(86, 88, 5, 6.5)],
  ),
  // 4 — in flower.
  _Stage(
    shadowRx: 58,
    stemColor: Color(0xFF4CA845),
    stalks: [
      _Stalk(100, 170, 94, 114, 100, 52, 7),
      _Stalk(99, 128, 120, 120, 132, 102, 5),
      _Stalk(99, 108, 78, 100, 67, 82, 5),
      _Stalk(100, 86, 114, 80, 122, 68, 4),
    ],
    leaves: [
      _Leaf(100, 162, -38, 0.80, Color(0xFF79CE5D)),
      _Leaf(100, 164, -142, 0.80, Color(0xFF57BF4C)),
      _Leaf(98, 144, -30, 1.00, Color(0xFF79CE5D)),
      _Leaf(98, 146, -150, 1.00, Color(0xFF57BF4C)),
      _Leaf(132, 102, -54, 0.66, Color(0xFF8AD46A)),
      _Leaf(67, 82, -126, 0.66, Color(0xFF8AD46A)),
      _Leaf(99, 124, -26, 0.88, Color(0xFF86D468)),
      _Leaf(99, 126, -154, 0.88, Color(0xFF64C554)),
      _Leaf(100, 100, -24, 0.72, Color(0xFF93DA76)),
      _Leaf(100, 102, -156, 0.72, Color(0xFF71CC5D)),
      _Leaf(122, 68, -52, 0.50, Color(0xFF9BDC7E)),
    ],
    flowers: [
      _Flower(100, 46, 12, 5),
      _Flower(80, 64, 8, 3.4),
      _Flower(120, 60, 8, 3.4),
    ],
  ),
];

class _PlantPainter extends CustomPainter {
  _PlantPainter(this.stage);

  final int stage;

  /// The drawing's own coordinate space, scaled to fit whatever box it is given.
  static const _designSize = Size(200, 230);

  /// One leaf, in leaf-local coordinates. Every leaf on every plant is this
  /// shape, moved, turned and resized.
  static final Path _leafPath = Path()
    ..moveTo(0, 0)
    ..cubicTo(8, -11, 30, -11, 40, 0)
    ..cubicTo(30, 11, 8, 11, 0, 0)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(
      size.width / _designSize.width,
      size.height / _designSize.height,
    );
    canvas.save();
    // Bottom-aligned and centred: the pot sits on the ground, whatever box it
    // is handed, so the plant grows UPWARD as the stages advance rather than
    // re-centring and appearing to shuffle.
    canvas.translate(
      (size.width - _designSize.width * scale) / 2,
      size.height - _designSize.height * scale,
    );
    canvas.scale(scale);

    final s = _stages[stage.clamp(0, Plant.maxStage)];

    // The pot's shadow on the ground.
    canvas.drawOval(
      Rect.fromCenter(
        center: const Offset(100, 222),
        width: s.shadowRx * 2,
        height: 18,
      ),
      Paint()..color = const Color(0x1A1C4A18),
    );

    // Stem and branches.
    for (final stalk in s.stalks) {
      final path = Path()
        ..moveTo(stalk.x0, stalk.y0)
        ..quadraticBezierTo(stalk.cx, stalk.cy, stalk.x1, stalk.y1);
      canvas.drawPath(
        path,
        Paint()
          ..color = s.stemColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = stalk.width
          ..strokeCap = StrokeCap.round,
      );
    }

    // Leaves.
    for (final leaf in s.leaves) {
      canvas.save();
      canvas.translate(leaf.x, leaf.y);
      canvas.rotate(leaf.rotation * math.pi / 180);
      canvas.scale(leaf.scale);
      canvas.drawPath(_leafPath, Paint()..color = leaf.color);
      canvas.restore();
    }

    // Buds, then open flowers.
    for (final bud in s.buds) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(bud.cx, bud.cy),
          width: bud.rx * 2,
          height: bud.ry * 2,
        ),
        Paint()..color = _budColor,
      );
    }
    for (final f in s.flowers) {
      canvas.drawCircle(
        Offset(f.cx, f.cy),
        f.r,
        Paint()..color = _petal,
      );
      canvas.drawCircle(
        Offset(f.cx, f.cy),
        f.rInner,
        Paint()..color = _pollen,
      );
    }

    // The pot last, so the lowest leaves sit behind its rim.
    final pot = Path()
      ..moveTo(64, 174)
      ..lineTo(136, 174)
      ..lineTo(128, 222)
      ..quadraticBezierTo(127, 227, 122, 227)
      ..lineTo(78, 227)
      ..quadraticBezierTo(73, 227, 72, 222)
      ..close();
    canvas.drawPath(pot, Paint()..color = _pot);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(57, 161, 86, 17),
        const Radius.circular(8),
      ),
      Paint()..color = _potRim,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_PlantPainter oldDelegate) => oldDelegate.stage != stage;
}
