import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../providers/edit_provider.dart';

/// Eyedropper for the Color Range mask.
///
/// Sits over the photo while a Color Range mask is selected, and reports
/// the colour under the finger as it moves. Sampling continuously during
/// the drag rather than only on lift is what makes it usable: the
/// selection updates live, so you can slide across the image and watch
/// the mask latch onto the thing you meant.
class ColorSampleOverlay extends StatefulWidget {
  const ColorSampleOverlay({super.key});

  @override
  State<ColorSampleOverlay> createState() => _ColorSampleOverlayState();
}

class _ColorSampleOverlayState extends State<ColorSampleOverlay> {
  Offset? _cursor;

  void _sample(Offset localPosition, Size size) {
    if (size.isEmpty) return;
    final normalized = Offset(
      (localPosition.dx / size.width).clamp(0.0, 1.0),
      (localPosition.dy / size.height).clamp(0.0, 1.0),
    );
    setState(() => _cursor = localPosition);
    context.read<EditProvider>().sampleMaskColorAt(normalized);
  }

  @override
  Widget build(BuildContext context) {
    final slot = context.watch<EditProvider>().selectedMask;
    final sampled = slot == null
        ? null
        : Color.from(
            alpha: 1,
            red: slot.colorR,
            green: slot.colorG,
            blue: slot.colorB,
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            HapticFeedback.selectionClick();
            _sample(d.localPosition, size);
          },
          onPanStart: (d) => _sample(d.localPosition, size),
          onPanUpdate: (d) => _sample(d.localPosition, size),
          onPanEnd: (_) => setState(() => _cursor = null),
          child: Stack(
            children: [
              if (_cursor != null && sampled != null)
                Positioned(
                  // Offset above-left of the finger so the loupe is not
                  // hidden under the hand that is placing it.
                  left: _cursor!.dx - 34,
                  top: _cursor!.dy - 82,
                  child: IgnorePointer(child: _Loupe(color: sampled)),
                ),
              if (_cursor == null)
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 12,
                  child: IgnorePointer(child: _SamplePrompt()),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The magnifier bubble showing what is under the finger.
class _Loupe extends StatelessWidget {
  final Color color;

  const _Loupe({required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 10,
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            _hex(color),
            style: AppText.value.copyWith(color: Colors.white, fontSize: 11),
          ),
        ),
      ],
    );
  }

  static String _hex(Color c) {
    int channel(double v) => (v * 255).round().clamp(0, 255);
    return '#'
        '${channel(c.r).toRadixString(16).padLeft(2, '0')}'
        '${channel(c.g).toRadixString(16).padLeft(2, '0')}'
        '${channel(c.b).toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();
  }
}

class _SamplePrompt extends StatelessWidget {
  const _SamplePrompt();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.accent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.colorize_rounded, size: 14, color: Colors.white),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Drag on the photo to pick a colour',
                style: AppText.chip.copyWith(color: Colors.white),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
