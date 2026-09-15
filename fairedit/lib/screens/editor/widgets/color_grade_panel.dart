import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/lr_panel.dart';
import '../../../core/widgets/lr_slider.dart';
import '../../../models/color_grade_state.dart';
import '../../../providers/edit_provider.dart';
import 'color_wheel.dart';
import 'feature_toolbar.dart';

/// Split-tone colour grading: a hue/saturation wheel per tonal range,
/// plus luminance for that range and one shared blending control.
class ColorGradePanel extends StatefulWidget {
  final VoidCallback onClose;

  const ColorGradePanel({super.key, required this.onClose});

  @override
  State<ColorGradePanel> createState() => _ColorGradePanelState();
}

class _ColorGradePanelState extends State<ColorGradePanel> {
  GradeRange _range = GradeRange.shadows;
  double _wheelSize = 160;

  static String _rangeLabel(GradeRange r) => switch (r) {
        GradeRange.shadows => 'Shadows',
        GradeRange.midtones => 'Midtones',
        GradeRange.highlights => 'Highlights',
      };

  void _handleWheelPoint(Offset local, GradeRange range) {
    final center = Offset(_wheelSize / 2, _wheelSize / 2);
    final delta = local - center;
    final maxDist = _wheelSize / 2 - 12;
    final distance = delta.distance.clamp(0.0, maxDist);
    var angle = math.atan2(delta.dy, delta.dx) * 180 / math.pi;
    if (angle < 0) angle += 360;
    context.read<EditProvider>().updateColorGradeRange(
          range,
          hue: angle,
          saturation: (distance / maxDist) * 100,
        );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final grading = provider.editState.colorGrade;
    final active = grading.forRange(_range);
    final read = context.read<EditProvider>;

    return LrPanel(
      title: EditorFeature.colour.panelTitle,
      icon: EditorFeature.colour.glyph,
      onDone: widget.onClose,
      onReset: active.isNeutral
          ? null
          : () => read().resetColorGradeRange(_range),
      hint: 'Drag the wheel to tint this range',
      maxHeight: 300,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LrChipRow(
            children: [
              for (final r in GradeRange.values)
                LrChip(
                  label: _rangeLabel(r),
                  // A dot would be ambiguous next to the wheel, so an
                  // edited range is marked with a filled glyph instead.
                  icon: grading.forRange(r).isNeutral
                      ? null
                      : Icons.brightness_1_rounded,
                  selected: r == _range,
                  onTap: () => setState(() => _range = r),
                ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              _wheelSize = math.min(constraints.maxWidth, 170.0);
              return Center(
                child: ColorWheel(
                  size: _wheelSize,
                  hue: active.hue,
                  saturation: active.saturation,
                  onPanStart: (local) {
                    read().beginAdjustmentGesture();
                    _handleWheelPoint(local, _range);
                  },
                  onPanUpdate: (local) => _handleWheelPoint(local, _range),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          LrSlider(
            label: 'Luminance',
            value: active.luminance,
            onChangeStart: () => read().beginAdjustmentGesture(),
            onChanged: (v) => read().updateColorGradeRange(_range, luminance: v),
          ),
          LrSlider(
            label: 'Blending',
            value: grading.blending,
            min: 0,
            max: 100,
            // Blending rests at its midpoint: that is the neutral overlap
            // between ranges, not zero.
            origin: 50,
            onChangeStart: () => read().beginAdjustmentGesture(),
            onChanged: (v) => read().updateColorGradeBlending(v),
          ),
        ],
      ),
    );
  }
}
