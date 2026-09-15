import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../../providers/edit_provider.dart';

/// Lets the user paint over a blemish or small object to mark it for
/// healing. Already-applied heals show directly in the photo itself
/// (the shader blends them in) — this overlay only highlights the
/// PENDING stroke, not yet baked in until HealBar's Apply is tapped.
class HealBrushOverlay extends StatelessWidget {
  const HealBrushOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final brushSizeFraction = provider.editState.heal.brushSize / 100;
    final points = provider.healStrokePoints;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final radiusPx = brushSizeFraction * (math.min(size.width, size.height) * 0.5);

        void addPoint(Offset local) {
          final x = (local.dx / size.width).clamp(0.0, 1.0);
          final y = (local.dy / size.height).clamp(0.0, 1.0);
          context.read<EditProvider>().addHealStrokePoint(Offset(x, y));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => addPoint(d.localPosition),
          onPanUpdate: (d) => addPoint(d.localPosition),
          child: CustomPaint(
            size: size,
            painter: _HealPreviewPainter(
              points: points,
              radiusPx: radiusPx,
              canvasSize: size,
            ),
          ),
        );
      },
    );
  }
}

class _HealPreviewPainter extends CustomPainter {
  final List<Offset> points;
  final double radiusPx;
  final Size canvasSize;

  _HealPreviewPainter({required this.points, required this.radiusPx, required this.canvasSize});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final paint = Paint()..color = AppColors.accent.withValues(alpha: 0.4);
    for (final p in points) {
      canvas.drawCircle(Offset(p.dx * size.width, p.dy * size.height), radiusPx, paint);
    }
    final outlinePaint = Paint()
      ..color = AppColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final p in points) {
      canvas.drawCircle(Offset(p.dx * size.width, p.dy * size.height), radiusPx, outlinePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _HealPreviewPainter oldDelegate) {
    return oldDelegate.points != points || oldDelegate.radiusPx != radiusPx;
  }
}
