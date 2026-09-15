import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/lr_panel.dart';
import '../../../core/widgets/lr_slider.dart';
import '../../../models/blur_state.dart';
import '../../../providers/edit_provider.dart';
import 'feature_toolbar.dart';

/// Lens Blur — a focus point (or an AI-detected subject) kept sharp with
/// a shaped bokeh falloff around it.
class BlurPanel extends StatelessWidget {
  final VoidCallback onClose;

  const BlurPanel({super.key, required this.onClose});

  static String _shapeLabel(BokehShape s) => switch (s) {
        BokehShape.circular => 'Circle',
        BokehShape.soapBubble => 'Soap',
        BokehShape.polygonal => 'Poly',
        BokehShape.ring => 'Ring',
        BokehShape.oval => 'Oval',
      };

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final blur = provider.editState.blur;
    final read = context.read<EditProvider>;

    return LrPanel(
      title: EditorFeature.blur.panelTitle,
      icon: EditorFeature.blur.glyph,
      onDone: onClose,
      onReset: blur.isNeutral ? null : () => read().resetBlur(),
      error: blur.useSubjectMask ? null : provider.subjectDetectionError,
      hint: blur.useSubjectMask
          ? 'Focus follows the detected subject — drag on the photo to take over'
          : 'Drag on the photo to move the focus point',
      maxHeight: 260,
      actions: [
        // Apply switch: lets the user A/B the whole effect without
        // losing the amount/size/bokeh values they dialled in.
        Transform.scale(
          scale: 0.75,
          child: Switch(
            value: blur.enabled,
            onChanged: (v) => read().setBlurEnabled(v),
          ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SubjectRow(
            active: blur.useSubjectMask,
            detecting: provider.isDetectingSubject,
            onTap: () {
              if (blur.useSubjectMask) {
                read().setUseSubjectMask(false);
              } else {
                read().detectSubject();
              }
            },
          ),
          LrSlider(
            label: 'Amount',
            value: blur.amount,
            min: 0,
            max: 100,
            enabled: blur.enabled,
            onChangeStart: () => read().beginAdjustmentGesture(),
            onChanged: (v) => read().updateBlurAmount(v),
          ),
          if (!blur.useSubjectMask)
            LrSlider(
              label: 'Focus Size',
              value: blur.size,
              min: 5,
              max: 80,
              enabled: blur.enabled,
              onChangeStart: () => read().beginAdjustmentGesture(),
              onChanged: (v) => read().updateBlurSize(v),
            ),
          const LrSectionHeader(label: 'Bokeh'),
          LrChipRow(
            children: [
              for (final shape in BokehShape.values)
                LrChip(
                  label: _shapeLabel(shape),
                  selected: shape == blur.bokehShape,
                  enabled: blur.enabled,
                  onTap: () => read().setBokehShape(shape),
                ),
            ],
          ),
          const SizedBox(height: 4),
          LrSlider(
            label: 'Cat Eye',
            value: blur.catEye,
            min: 0,
            max: 100,
            enabled: blur.enabled,
            onChangeStart: () => read().beginAdjustmentGesture(),
            onChanged: (v) => read().updateCatEye(v),
          ),
          LrSlider(
            label: 'Boost',
            value: blur.bokehBoost,
            min: 0,
            max: 100,
            enabled: blur.enabled,
            onChangeStart: () => read().beginAdjustmentGesture(),
            onChanged: (v) => read().updateBokehBoost(v),
          ),
        ],
      ),
    );
  }
}

/// "Select Subject" affordance — a full-width row rather than the old
/// bare icon, because running on-device segmentation is a deliberate,
/// second-or-two operation and deserves a control that says what it does
/// and reports when it has done it.
class _SubjectRow extends StatelessWidget {
  final bool active;
  final bool detecting;
  final VoidCallback onTap;

  const _SubjectRow({
    required this.active,
    required this.detecting,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: detecting ? null : onTap,
          borderRadius: BorderRadius.circular(AppLayout.radiusMd),
          child: AnimatedContainer(
            duration: AppMotion.fast,
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: active ? AppColors.accentSubtle : AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(AppLayout.radiusMd),
              border: Border.all(
                color: active ? AppColors.accent : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                if (detecting)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    active
                        ? Icons.check_circle_rounded
                        : Icons.person_search_rounded,
                    size: 17,
                    color: active ? AppColors.accent : AppColors.textSecondary,
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    detecting
                        ? 'Detecting subject…'
                        : active
                            ? 'Focused on detected subject'
                            : 'Select Subject',
                    style: AppText.chip.copyWith(
                      color: active
                          ? AppColors.accent
                          : AppColors.textPrimary,
                    ),
                  ),
                ),
                if (active && !detecting)
                  const Text('Tap to undo', style: AppText.hint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
