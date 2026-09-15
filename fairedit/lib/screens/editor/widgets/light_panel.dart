import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/lr_panel.dart';
import '../../../core/widgets/lr_slider.dart';
import '../../../models/edit_state.dart';
import '../../../providers/edit_provider.dart';
import 'feature_toolbar.dart';

/// Tone and colour-balance sliders — Lightroom's "Light" and "Color"
/// panels, merged into one scrolling surface.
///
/// This replaces the previous single-slider-plus-pie-menu bar. That
/// design showed one parameter at a time, which meant you could not see
/// that (say) Highlights was already at -40 while pulling Shadows up, and
/// grading tone is entirely about the relationship *between* those
/// values. Showing the whole set, with every non-zero value visible at a
/// glance, is why Lightroom's panel is a list.
class LightPanel extends StatelessWidget {
  final VoidCallback onClose;

  const LightPanel({super.key, required this.onClose});

  static const _light = [
    AdjustmentType.exposure,
    AdjustmentType.contrast,
    AdjustmentType.highlights,
    AdjustmentType.shadows,
    AdjustmentType.whites,
    AdjustmentType.blacks,
    AdjustmentType.brightness,
  ];

  static const _colour = [
    AdjustmentType.warmth,
    AdjustmentType.tint,
    AdjustmentType.vibrance,
    AdjustmentType.saturation,
  ];

  /// Ramps only where the parameter's axis genuinely is a colour. A
  /// gradient on Exposure would be decoration; on Temperature it tells
  /// you which way is warmer without reading the number.
  static List<Color>? _rampFor(AdjustmentType type) => switch (type) {
        AdjustmentType.warmth => AppRamps.temperature,
        AdjustmentType.tint => AppRamps.tint,
        AdjustmentType.saturation ||
        AdjustmentType.vibrance =>
          AppRamps.saturation,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final state = provider.editState;

    Widget sliderFor(AdjustmentType type) => LrSlider(
          label: type.label,
          value: type.valueOf(state),
          onChangeStart: () =>
              context.read<EditProvider>().beginAdjustmentGesture(),
          onChanged: (v) =>
              context.read<EditProvider>().setAdjustment(type, v),
          trackGradient: _rampFor(type),
        );

    return LrPanel(
      title: EditorFeature.light.panelTitle,
      icon: EditorFeature.light.glyph,
      onDone: onClose,
      onReset: state.isAdjustmentsNeutral
          ? null
          : () => context.read<EditProvider>().resetAdjustments(),
      maxHeight: 268,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // No "LIGHT" section header here: the rail item, the panel
          // header and this would have said the same word three times in
          // a row. The first group needs no label when the panel is
          // already named after it.
          for (final type in _light) sliderFor(type),
          const LrSectionHeader(label: 'Color'),
          for (final type in _colour) sliderFor(type),
        ],
      ),
    );
  }
}
