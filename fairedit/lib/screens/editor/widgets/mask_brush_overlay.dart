import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../../providers/edit_provider.dart';

/// Paints the pending brush stroke for a Brush-type mask. Same idea as
/// HealBrushOverlay, but tied to whichever mask is currently selected
/// rather than the single global heal mask. A fixed brush size is used
/// for v1 (matches HealEngine's default) rather than a per-mask control.
class MaskBrushOverlay extends StatelessWidget {
  const MaskBrushOverlay({super.key});

  static const double brushSizeFraction = 0.12;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final points = provider.maskStrokePoints;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final radiusPx = brushSizeFraction * (size.shortestSide * 0.5);

        void addPoint(Offset local) {
          final x = (local.dx / size.width).clamp(0.0, 1.0);
          final y = (local.dy / size.height).clamp(0.0, 1.0);
          context.read<EditProvider>().addMaskStrokePoint(Offset(x, y));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => addPoint(d.localPosition),
          onPanUpdate: (d) => addPoint(d.localPosition),
          child: CustomPaint(
            size: size,
            painter: _MaskBrushPreviewPainter(points: points, radiusPx: radiusPx),
          ),
        );
      },
    );
  }
}

class _MaskBrushPreviewPainter extends CustomPainter {
  final List<Offset> points;
  final double radiusPx;

  _MaskBrushPreviewPainter({required this.points, required this.radiusPx});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final fill = Paint()..color = AppColors.accent.withValues(alpha: 0.4);
    final outline = Paint()
      ..color = AppColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final p in points) {
      final center = Offset(p.dx * size.width, p.dy * size.height);
      canvas.drawCircle(center, radiusPx, fill);
      canvas.drawCircle(center, radiusPx, outline);
    }
  }

  @override
  bool shouldRepaint(covariant _MaskBrushPreviewPainter oldDelegate) {
    return oldDelegate.points != points;
  }
}
