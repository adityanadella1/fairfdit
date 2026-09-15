import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/mask_state.dart';
import '../../../providers/edit_provider.dart';

enum _Handle { linearStart, linearEnd, radialCenter, radialEdgeX, radialEdgeY }

/// Interactive shape editor for Linear and Radial masks — a draggable
/// line for Linear, a draggable/resizable circle for Radial. Brush-type
/// masks use MaskBrushOverlay instead (a different interaction entirely).
class MaskGradientOverlay extends StatefulWidget {
  const MaskGradientOverlay({super.key});

  @override
  State<MaskGradientOverlay> createState() => _MaskGradientOverlayState();
}

class _MaskGradientOverlayState extends State<MaskGradientOverlay> {
  _Handle? _activeHandle;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final mask = provider.selectedMask;
    if (mask == null) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        Offset toPixel(double x, double y) => Offset(x * size.width, y * size.height);

        _Handle? hitTest(Offset local) {
          const threshold = 30.0;
          if (mask.type == MaskShapeType.linear) {
            final start = toPixel(mask.linearStartX, mask.linearStartY);
            final end = toPixel(mask.linearEndX, mask.linearEndY);
            if ((local - start).distance < threshold) return _Handle.linearStart;
            if ((local - end).distance < threshold) return _Handle.linearEnd;
          } else if (mask.type == MaskShapeType.radial) {
            final center = toPixel(mask.radialCenterX, mask.radialCenterY);
            final edgeX = center + Offset(mask.radialRadiusX * size.width, 0);
            final edgeY = center + Offset(0, -mask.radialRadiusY * size.height);
            if ((local - edgeX).distance < threshold) return _Handle.radialEdgeX;
            if ((local - edgeY).distance < threshold) return _Handle.radialEdgeY;
            if ((local - center).distance < threshold) return _Handle.radialCenter;
          }
          return null;
        }

        void handleDrag(Offset local) {
          final edit = context.read<EditProvider>();
          final x = (local.dx / size.width).clamp(0.0, 1.0);
          final y = (local.dy / size.height).clamp(0.0, 1.0);

          switch (_activeHandle!) {
            case _Handle.linearStart:
              edit.updateMaskLinear(startX: x, startY: y);
              break;
            case _Handle.linearEnd:
              edit.updateMaskLinear(endX: x, endY: y);
              break;
            case _Handle.radialCenter:
              edit.updateMaskRadial(centerX: x, centerY: y);
              break;
            case _Handle.radialEdgeX:
              final center = Offset(mask.radialCenterX * size.width, mask.radialCenterY * size.height);
              final radiusX = ((local.dx - center.dx).abs() / size.width).clamp(0.03, 1.0);
              edit.updateMaskRadial(radiusX: radiusX);
              break;
            case _Handle.radialEdgeY:
              final center = Offset(mask.radialCenterX * size.width, mask.radialCenterY * size.height);
              final radiusY = ((local.dy - center.dy).abs() / size.height).clamp(0.03, 1.0);
              edit.updateMaskRadial(radiusY: radiusY);
              break;
          }
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            final handle = hitTest(d.localPosition);
            if (handle == null) return;
            _activeHandle = handle;
            context.read<EditProvider>().beginAdjustmentGesture();
          },
          onPanUpdate: (d) {
            if (_activeHandle == null) return;
            handleDrag(d.localPosition);
          },
          onPanEnd: (_) => _activeHandle = null,
          child: CustomPaint(
            size: size,
            painter: _MaskShapePainter(mask: mask, size: size),
          ),
        );
      },
    );
  }
}

class _MaskShapePainter extends CustomPainter {
  final MaskSlot mask;
  final Size size;

  _MaskShapePainter({required this.mask, required this.size});

  @override
  void paint(Canvas canvas, Size paintSize) {
    final handleFill = Paint()..color = Colors.white;
    final handleStroke = Paint()
      ..color = Colors.black45
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final linePaint = Paint()
      ..color = AppColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    if (mask.type == MaskShapeType.linear) {
      final start = Offset(mask.linearStartX * size.width, mask.linearStartY * size.height);
      final end = Offset(mask.linearEndX * size.width, mask.linearEndY * size.height);
      _paintLinearGlow(canvas, start, end);
      canvas.drawLine(start, end, linePaint);
      // Perpendicular tick marks at each end, hinting at the gradient band.
      final dir = (end - start);
      final len = dir.distance;
      if (len > 0.001) {
        final unit = dir / len;
        final perp = Offset(-unit.dy, unit.dx) * 22;
        canvas.drawLine(start - perp, start + perp, linePaint);
        canvas.drawLine(end - perp, end + perp, linePaint);
      }
      for (final p in [start, end]) {
        canvas.drawCircle(p, 9, handleStroke);
        canvas.drawCircle(p, 7, handleFill);
      }
    } else if (mask.type == MaskShapeType.radial) {
      final center = Offset(mask.radialCenterX * size.width, mask.radialCenterY * size.height);
      final radiusX = mask.radialRadiusX * size.width;
      final radiusY = mask.radialRadiusY * size.height;
      _paintRadialGlow(canvas, center, radiusX, radiusY, mask.radialFeather, mask.invert);
      final rect = Rect.fromCenter(center: center, width: radiusX * 2, height: radiusY * 2);
      canvas.drawOval(rect, linePaint);

      final edgeX = center + Offset(radiusX, 0);
      final edgeY = center + Offset(0, -radiusY);
      for (final p in [center, edgeX, edgeY]) {
        canvas.drawCircle(p, 9, handleStroke);
        canvas.drawCircle(p, 7, handleFill);
      }
    }
  }

  /// Shades the affected region so the user can see the mask's actual
  /// falloff, not just its outline. Mirrors the shape's own feather/invert
  /// so the highlight matches what the shader will actually apply.
  void _paintLinearGlow(Canvas canvas, Offset start, Offset end) {
    final colors = mask.invert
        ? [AppColors.accent.withValues(alpha: 0.4), Colors.transparent]
        : [Colors.transparent, AppColors.accent.withValues(alpha: 0.4)];
    final paint = Paint()..shader = ui.Gradient.linear(start, end, colors);
    canvas.drawRect(Offset.zero & size, paint);
  }

  void _paintRadialGlow(Canvas canvas, Offset center, double radiusX, double radiusY, double feather, bool invert) {
    if (radiusX <= 0 || radiusY <= 0) return;
    final innerStop = (1.0 - feather.clamp(0.0, 1.0));
    final colors = invert
        ? [Colors.transparent, Colors.transparent, AppColors.accent.withValues(alpha: 0.45)]
        : [AppColors.accent.withValues(alpha: 0.45), AppColors.accent.withValues(alpha: 0.45), Colors.transparent];
    final paint = Paint()
      ..shader = ui.Gradient.radial(Offset.zero, 1.0, colors, [0.0, innerStop, 1.0]);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(radiusX, radiusY);
    canvas.drawRect(const Rect.fromLTWH(-1, -1, 2, 2), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MaskShapePainter oldDelegate) => oldDelegate.mask != mask;
}
