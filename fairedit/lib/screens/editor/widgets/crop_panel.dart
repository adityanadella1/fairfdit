import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/lr_panel.dart';
import '../../../core/widgets/lr_slider.dart';
import '../../../providers/edit_provider.dart';
import 'crop_overlay.dart';
import 'feature_toolbar.dart';

/// Crop, straighten, rotate and flip.
///
/// The transform buttons sit on their own row above the aspect presets
/// because they are one-shot actions while the presets are a persistent
/// selection — mixing the two in one scrolling strip, as the old bar did,
/// meant the rotate button scrolled out of reach once you had a few
/// presets in view.
class CropPanel extends StatelessWidget {
  final VoidCallback onClose;

  const CropPanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final crop = provider.editState.crop;

    return LrPanel(
      title: EditorFeature.crop.panelTitle,
      icon: EditorFeature.crop.glyph,
      onDone: onClose,
      onReset:
          crop.isNeutral ? null : () => context.read<EditProvider>().resetCrop(),
      hint: 'Drag the corners on the photo to crop',
      maxHeight: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              LrIconToggle(
                icon: Icons.rotate_90_degrees_ccw_outlined,
                tooltip: 'Rotate 90°',
                onTap: () => context.read<EditProvider>().rotateCrop90(),
              ),
              LrIconToggle(
                icon: Icons.flip,
                tooltip: 'Flip horizontal',
                selected: crop.flipHorizontal,
                onTap: () => context.read<EditProvider>().toggleFlipHorizontal(),
              ),
              LrIconToggle(
                icon: Icons.flip,
                tooltip: 'Flip vertical',
                selected: crop.flipVertical,
                turns: 0.25,
                onTap: () => context.read<EditProvider>().toggleFlipVertical(),
              ),
              const SizedBox(width: 4),
              Container(width: 1, height: 22, color: AppColors.divider),
              const SizedBox(width: 10),
              Expanded(
                child: LrChipRow(
                  children: [
                    LrChip(
                      label: 'Free',
                      selected: crop.aspectPresetLabel == null,
                      onTap: () => context
                          .read<EditProvider>()
                          .setCropAspectPreset(null, null),
                    ),
                    LrChip(
                      label: 'Original',
                      selected: crop.aspectPresetLabel == 'Original',
                      onTap: () =>
                          context.read<EditProvider>().setCropOriginalPreset(),
                    ),
                    for (final entry in cropAspectPixelRatios.entries)
                      LrChip(
                        label: entry.key,
                        selected: crop.aspectPresetLabel == entry.key,
                        onTap: () => context
                            .read<EditProvider>()
                            .setCropAspectPreset(entry.value, entry.key),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LrSlider(
            label: 'Straighten',
            value: crop.straightenAngle,
            min: -45,
            max: 45,
            unit: '°',
            onChangeStart: () =>
                context.read<EditProvider>().beginAdjustmentGesture(),
            onChanged: (v) => context.read<EditProvider>().updateStraighten(v),
          ),
        ],
      ),
    );
  }
}
