import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A soft ring that expands and contracts, peaking exactly on the beat.
///
/// It listens to the engine's [phase] (0.0 on the beat → 1.0 just before the
/// next). We turn that into a smooth "breathing" pulse with a cosine so the
/// ring is biggest/brightest right on the beat and smallest halfway between —
/// no harsh snapping.
class MetronomeRing extends StatelessWidget {
  const MetronomeRing({
    super.key,
    required this.phase,
    required this.enabled,
    this.size = 220,
    this.color = Colors.teal,
  });

  /// 0.0 on the beat, rising to 1.0 just before the next.
  final ValueListenable<double> phase;

  /// When false the ring is shown faint and still (visual channel off).
  final bool enabled;

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      // A calm, static ring so the layout doesn't jump when toggled off.
      return _ring(scale: 0.85, opacity: 0.15);
    }
    return ValueListenableBuilder<double>(
      valueListenable: phase,
      builder: (context, p, _) {
        // pulse: 1.0 on the beat (p=0 or 1), 0.0 halfway between.
        final pulse = 0.5 * (1 + math.cos(2 * math.pi * p));
        return _ring(
          scale: 0.7 + 0.3 * pulse,
          opacity: 0.3 + 0.6 * pulse,
        );
      },
    );
  }

  Widget _ring({required double scale, required double opacity}) {
    return Center(
      child: Transform.scale(
        scale: scale,
        child: Opacity(
          opacity: opacity,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 14),
            ),
          ),
        ),
      ),
    );
  }
}
