import 'package:flutter/material.dart';

/// A "slide to unlock" control. The caregiver must deliberately drag the thumb
/// from left to right to trigger [onUnlocked]; plain taps do nothing. This stops
/// the user from opening the settings portal by accident (brief §5).
class SlideToUnlock extends StatefulWidget {
  const SlideToUnlock({
    super.key,
    required this.onUnlocked,
    this.label = 'Slide to open settings',
  });

  final VoidCallback onUnlocked;
  final String label;

  @override
  State<SlideToUnlock> createState() => _SlideToUnlockState();
}

class _SlideToUnlockState extends State<SlideToUnlock> {
  static const double _height = 56;
  static const double _thumb = 56;

  double _dx = 0; // current thumb offset from the left, in pixels
  double _maxDx = 0; // furthest the thumb can travel (set in build)

  void _onDragUpdate(DragUpdateDetails d) {
    setState(() => _dx = (_dx + d.delta.dx).clamp(0.0, _maxDx));
  }

  void _onDragEnd(DragEndDetails _) {
    // Counts as unlocked only if dragged most of the way across.
    final unlocked = _maxDx > 0 && _dx >= _maxDx * 0.9;
    setState(() => _dx = 0); // snap back either way
    if (unlocked) widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        _maxDx = constraints.maxWidth - _thumb;
        return Container(
          height: _height,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(_height / 2),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(widget.label,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              Positioned(
                left: _dx,
                child: GestureDetector(
                  key: const Key('slide_thumb'),
                  onHorizontalDragUpdate: _onDragUpdate,
                  onHorizontalDragEnd: _onDragEnd,
                  child: Container(
                    width: _thumb,
                    height: _thumb,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.lock_open, color: scheme.onPrimary),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
