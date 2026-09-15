import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A circular hue/saturation picker: angle around the wheel = hue (0..360),
/// distance from center = saturation/strength (0..100). Center = neutral.
class ColorWheel extends StatelessWidget {
  final double size;
  final double hue;
  final double saturation;
  final ValueChanged<Offset> onPanStart;
  final ValueChanged<Offset> onPanUpdate;
  final VoidCallback? onPanEnd;

  const ColorWheel({
    super.key,
    required this.size,
    required this.hue,
    required this.saturation,
    required this.onPanStart,
    required this.onPanUpdate,
    this.onPanEnd,
  });

  @override
  Widget build(BuildContext context) {
    final radius = size / 2;
    final angleRad = hue * math.pi / 180;
    final distance = (saturation / 100).clamp(0.0, 1.0) * (radius - 12);
    final puckCenter = Offset(
      radius + math.cos(angleRad) * distance,
      radius + math.sin(angleRad) * distance,
    );

    return GestureDetector(
      onPanStart: (d) => onPanStart(d.localPosition),
      onPanUpdate: (d) => onPanUpdate(d.localPosition),
      onPanEnd: (_) => onPanEnd?.call(),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Hue ring, desaturating toward white at the center — a sweep
            // gradient (hue) with a white-to-transparent radial gradient
            // painted over it fakes a proper HSV wheel without a custom
            // per-pixel shader.
            Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [
                    Color(0xFFFF0000),
                    Color(0xFFFFFF00),
                    Color(0xFF00FF00),
                    Color(0xFF00FFFF),
                    Color(0xFF0000FF),
                    Color(0xFFFF00FF),
                    Color(0xFFFF0000),
                  ],
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Colors.white, Colors.white.withValues(alpha: 0)],
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24, width: 1),
              ),
            ),
            // Center neutral dot.
            Container(
              width: 4,
              height: 4,
              decoration: const BoxDecoration(color: Colors.white38, shape: BoxShape.circle),
            ),
            // Puck.
            Positioned(
              left: puckCenter.dx - 9,
              top: puckCenter.dy - 9,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: saturation > 0
                      ? HSVColor.fromAHSV(1, hue, (saturation / 100).clamp(0.0, 1.0), 1).toColor()
                      : Colors.white,
                  border: Border.all(color: Colors.white, width: 2.5),
                  boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 3)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
