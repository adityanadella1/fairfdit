import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/lr_panel.dart';
import '../../../core/widgets/lr_slider.dart';
import '../../../models/effects_state.dart';
import '../../../providers/edit_provider.dart';
import 'feature_toolbar.dart';

/// Effects — Lightroom groups these as Detail (sharpen/clarity/dehaze)
/// and Effects (vignette/grain). The "size" controls are nested under the
/// amount they modify, since a grain size means nothing until there is
/// grain to size.
class EffectsPanel extends StatelessWidget {
  final VoidCallback onClose;

  const EffectsPanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final effects = provider.editState.effects;

    Widget sliderFor(EffectType type, {bool enabled = true}) => LrSlider(
          label: type.label,
          value: type.valueOf(effects),
          min: type.min,
          max: type.max,
          // The two "size" controls rest at their midpoint rather than at
          // zero — that is where they have no visible influence, so that
          // is what double-tap-to-reset has to return to.
          origin: _originFor(type),
          enabled: enabled,
          onChangeStart: () =>
              context.read<EditProvider>().beginAdjustmentGesture(),
          onChanged: (v) => context.read<EditProvider>().setEffect(type, v),
        );

    return LrPanel(
      title: EditorFeature.effects.panelTitle,
      icon: EditorFeature.effects.glyph,
      onDone: onClose,
      onReset: effects.isNeutral
          ? null
          : () => context.read<EditProvider>().resetEffects(),
      maxHeight: 268,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LrSectionHeader(label: 'Detail', topSpacing: false),
          sliderFor(EffectType.sharpen),
          sliderFor(EffectType.clarity),
          sliderFor(EffectType.dehaze),
          const LrSectionHeader(label: 'Vignette'),
          sliderFor(EffectType.vignetteAmount),
          sliderFor(
            EffectType.vignetteSize,
            enabled: effects.vignetteAmount != 0,
          ),
          const LrSectionHeader(label: 'Grain'),
          sliderFor(EffectType.grainAmount),
          sliderFor(EffectType.grainSize, enabled: effects.grainAmount != 0),
        ],
      ),
    );
  }

  double _originFor(EffectType type) => switch (type) {
        EffectType.vignetteSize || EffectType.grainSize => 50,
        _ => type.min < 0 ? 0 : type.min,
      };
}
