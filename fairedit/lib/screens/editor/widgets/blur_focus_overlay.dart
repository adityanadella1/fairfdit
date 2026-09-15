import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/edit_provider.dart';

/// The draggable focus-point ring shown over the photo while Blur is
/// active. Meant to be passed as EditorImageStack's `overlay`.
class BlurInteractionLayer extends StatelessWidget {
  const BlurInteractionLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final blur = context.watch<EditProvider>().editState.blur;

    return LayoutBuilder(
      builder: (context, constraints) {
        // StackFit.expand on the parent Stack means these constraints are
        // tight and exactly equal to the photo's own rendered size.
        final size = constraints.biggest;
        final focusPos = Offset(blur.focusX * size.width, blur.focusY * size.height);
        final radiusPx = (blur.size / 100) * (math.min(size.width, size.height) * 0.5);

        void updateFocus(Offset local) {
          final x = (local.dx / size.width).clamp(0.0, 1.0);
          final y = (local.dy / size.height).clamp(0.0, 1.0);
          context.read<EditProvider>().updateBlurFocus(x, y);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            context.read<EditProvider>().beginAdjustmentGesture();
            updateFocus(d.localPosition);
          },
          onPanUpdate: (d) => updateFocus(d.localPosition),
          child: CustomPaint(
            size: size,
            painter: _FocusRingPainter(
              center: focusPos,
              radius: radiusPx,
              visible: !blur.useSubjectMask,
            ),
          ),
        );
      },
    );
  }
}

class _FocusRingPainter extends CustomPainter {
  final Offset center;
  final double radius;
  final bool visible;

  _FocusRingPainter({required this.center, required this.radius, required this.visible});

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.black45
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(center, 5, Paint()..color = Colors.black45);
    canvas.drawCircle(center, 4, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _FocusRingPainter oldDelegate) {
    return oldDelegate.center != center ||
        oldDelegate.radius != radius ||
        oldDelegate.visible != visible;
  }
}
