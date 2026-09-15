import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/editor_icons.dart';
import '../../../core/widgets/lr_panel.dart';
import '../../../core/widgets/lr_range_slider.dart';
import '../../../core/widgets/lr_slider.dart';
import '../../../models/mask_state.dart';
import '../../../providers/edit_provider.dart';
import 'feature_toolbar.dart';

/// Masking, in two states inside one panel frame: the list of masks, and
/// the editor for whichever mask is selected.
///
/// Keeping both in the same [LrPanel] rather than pushing a route means
/// the photo never leaves the screen — you are always looking at the
/// thing you are masking, which is the whole point of local adjustments.
class MaskPanel extends StatelessWidget {
  final VoidCallback onClose;

  const MaskPanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final selected = provider.selectedMask;

    if (selected == null) {
      return _MaskListPanel(onClose: onClose);
    }
    return _MaskEditorPanel(mask: selected, onClose: onClose);
  }
}

// ---------------------------------------------------------------------
// List state
// ---------------------------------------------------------------------

class _MaskListPanel extends StatelessWidget {
  final VoidCallback onClose;

  const _MaskListPanel({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final masking = provider.editState.masking;
    final read = context.read<EditProvider>;
    final isFull = masking.isFull;

    return LrPanel(
      title: EditorFeature.mask.panelTitle,
      icon: EditorFeature.mask.glyph,
      onDone: onClose,
      onReset: masking.isNeutral ? null : () => read().resetMasking(),
      error: provider.aiMaskError,
      hint: isFull
          ? 'Up to ${MaskingState.maxSlots} masks — delete one to add another'
          : 'Add a mask, then adjust only that area',
      maxHeight: 300,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (masking.slots.isNotEmpty) ...[
            for (final slot in masking.slots) _MaskRow(slot: slot),
            const SizedBox(height: 6),
          ],
          const LrSectionHeader(
            label: 'Add mask',
            topSpacing: false,
          ),
          _AddMaskGrid(enabled: !isFull),
        ],
      ),
    );
  }
}

/// One row in the mask list: visibility toggle, icon, name, state and a
/// delete affordance.
class _MaskRow extends StatelessWidget {
  final MaskSlot slot;

  const _MaskRow({required this.slot});

  EditorGlyph get _glyph => switch (slot.type) {
        MaskShapeType.linear => EditorGlyph.linearGradient,
        MaskShapeType.radial => EditorGlyph.radialGradient,
        MaskShapeType.brush => EditorGlyph.brush,
        MaskShapeType.luminanceRange => EditorGlyph.luminanceRange,
        MaskShapeType.colorRange => EditorGlyph.colorRange,
        MaskShapeType.ai => _AddMaskGrid.glyphFor(slot.aiMode),
      };

  @override
  Widget build(BuildContext context) {
    final read = context.read<EditProvider>();
    final dim = !slot.enabled;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppLayout.radiusMd),
        child: InkWell(
          onTap: slot.aiPending ? null : () => read.selectMask(slot.id),
          borderRadius: BorderRadius.circular(AppLayout.radiusMd),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    slot.enabled
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                    size: 17,
                  ),
                  color: slot.enabled
                      ? AppColors.textSecondary
                      : AppColors.textDisabled,
                  tooltip: slot.enabled ? 'Hide mask' : 'Show mask',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => read.setMaskEnabled(slot.id, !slot.enabled),
                ),
                if (slot.aiPending)
                  const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  EditorIcon(
                    _glyph,
                    size: 18,
                    color: dim ? AppColors.textDisabled : AppColors.accent,
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        slot.typeLabel,
                        style: AppText.chip.copyWith(
                          color: dim
                              ? AppColors.textDisabled
                              : AppColors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        slot.aiPending
                            ? 'Selecting…'
                            : slot.hasAdjustments
                                ? 'Adjusted'
                                : 'No adjustments yet',
                        style: AppText.hint,
                      ),
                    ],
                  ),
                ),
                if (slot.type == MaskShapeType.ai && !slot.aiPending)
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    color: AppColors.textSecondary,
                    tooltip: 'Re-run selection',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => read.regenerateAiMask(slot.id),
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  color: AppColors.textTertiary,
                  tooltip: 'Delete mask',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => read.deleteMask(slot.id),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "Add Mask" chooser.
///
/// AI selections come first and are visually distinct from the manual
/// shapes, because they are what a Lightroom user reaches for first
/// ("select the subject") and because they behave differently — they run
/// a job and can fail, where dropping a radial gradient cannot.
class _AddMaskGrid extends StatelessWidget {
  final bool enabled;

  const _AddMaskGrid({required this.enabled});

  Future<void> _addAi(BuildContext context, AiMaskMode mode) async {
    final read = context.read<EditProvider>();
    String? prompt;
    if (mode.needsPrompt) {
      prompt = await _promptForObject(context);
      if (prompt == null || prompt.trim().isEmpty) return;
    }
    await read.addAiMask(mode, prompt: prompt);
  }

  Future<String?> _promptForObject(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Select object', style: AppText.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Name what to select — one noun works best.',
              style: AppText.hint,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              style: AppText.control.copyWith(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                hintText: 'car, dog, tree, phone…',
                hintStyle: AppText.hint,
                filled: true,
                fillColor: AppColors.surfaceRaised,
                border: OutlineInputBorder(borderSide: BorderSide.none),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Select'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final read = context.read<EditProvider>;
    final aiReady = provider.aiAvailable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Wrap, not a scrolling row. A horizontal strip clipped
        // "Background" mid-word at the screen edge with no visual cue
        // that it scrolled — a label you cannot finish reading is worse
        // than one on a second line.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final mode in AiMaskMode.values)
              LrChip(
                label: mode.label,
                glyph: glyphFor(mode),
                selected: false,
                enabled: enabled && aiReady,
                onTap: () => _addAi(context, mode),
              ),
          ],
        ),
        if (!aiReady)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                const Icon(
                  Icons.cloud_off_rounded,
                  size: 13,
                  color: AppColors.textTertiary,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'AI selection needs the FairEdit AI server',
                    style: AppText.hint,
                  ),
                ),
                TextButton(
                  onPressed: () => read().refreshAiAvailability(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ManualMaskButton(
                glyph: EditorGlyph.brush,
                label: 'Brush',
                enabled: enabled,
                onTap: () => read().addMask(MaskShapeType.brush),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ManualMaskButton(
                glyph: EditorGlyph.linearGradient,
                label: 'Linear',
                enabled: enabled,
                onTap: () => read().addMask(MaskShapeType.linear),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ManualMaskButton(
                glyph: EditorGlyph.radialGradient,
                label: 'Radial',
                enabled: enabled,
                onTap: () => read().addMask(MaskShapeType.radial),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Range masks select by pixel value rather than by position, so
        // they get their own row — grouping them with the shape tools
        // implied they were drawn, which they are not.
        Row(
          children: [
            Expanded(
              child: _ManualMaskButton(
                glyph: EditorGlyph.luminanceRange,
                label: 'Luminance',
                enabled: enabled,
                onTap: () => read().addMask(MaskShapeType.luminanceRange),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ManualMaskButton(
                glyph: EditorGlyph.colorRange,
                label: 'Color Range',
                enabled: enabled,
                onTap: () => read().addMask(MaskShapeType.colorRange),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Null maps to the subject glyph — an AI slot always had a mode when
  /// it was created, so null only occurs for state written by an older
  /// build of the app.
  static EditorGlyph glyphFor(AiMaskMode? mode) => switch (mode) {
        AiMaskMode.subject || null => EditorGlyph.subject,
        AiMaskMode.person => EditorGlyph.person,
        AiMaskMode.object => EditorGlyph.object,
        AiMaskMode.background => EditorGlyph.background,
        AiMaskMode.sky => EditorGlyph.sky,
      };
}

class _ManualMaskButton extends StatelessWidget {
  final EditorGlyph glyph;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  const _ManualMaskButton({
    required this.glyph,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? AppColors.textSecondary : AppColors.textDisabled;
    return Material(
      color: AppColors.surfaceRaised,
      borderRadius: BorderRadius.circular(AppLayout.radiusMd),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppLayout.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: [
              EditorIcon(glyph, size: 20, color: fg),
              const SizedBox(height: 4),
              Text(label, style: AppText.caption.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Editor state
// ---------------------------------------------------------------------

/// Shows what the eyedropper picked, or prompts for a sample.
///
/// A swatch rather than a hex string alone: the user sampled a colour
/// off a photo, and the thing that confirms they hit the right pixel is
/// seeing that colour, not reading its coordinates.
class _SampledColorRow extends StatelessWidget {
  final MaskSlot mask;

  const _SampledColorRow({required this.mask});

  @override
  Widget build(BuildContext context) {
    final sampled = mask.colorSampled;
    final color = Color.from(
      alpha: 1,
      red: mask.colorR,
      green: mask.colorG,
      blue: mask.colorB,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: sampled ? color : AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(AppLayout.radiusSm),
              border: Border.all(
                color: sampled ? AppColors.divider : AppColors.textDisabled,
              ),
            ),
            child: sampled
                ? null
                : const Icon(
                    Icons.colorize_rounded,
                    size: 16,
                    color: AppColors.textTertiary,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              sampled
                  ? 'Sampled colour · drag the photo to change'
                  : 'Drag on the photo to pick a colour',
              style: AppText.hint.copyWith(
                color: sampled ? AppColors.textSecondary : AppColors.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MaskEditorPanel extends StatelessWidget {
  final MaskSlot mask;
  final VoidCallback onClose;

  const _MaskEditorPanel({required this.mask, required this.onClose});

  String get _hint => switch (mask.type) {
        MaskShapeType.brush => 'Paint over the area, then Apply',
        MaskShapeType.ai => 'Refine the edge, or invert to select the rest',
        MaskShapeType.luminanceRange =>
          'Selects by brightness — narrow the band to target tones',
        MaskShapeType.colorRange => mask.colorSampled
            ? 'Drag on the photo to re-sample the colour'
            : 'Drag on the photo to pick a colour',
        _ => 'Drag on the photo to shape the mask',
      };

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final read = context.read<EditProvider>;
    final busy = provider.isApplyingMaskBrush;

    return LrPanel(
      title: mask.typeLabel,
      icon: EditorFeature.mask.glyph,
      onDone: onClose,
      busy: busy,
      error: provider.aiMaskError,
      hint: _hint,
      maxHeight: 290,
      onReset: mask.hasAdjustments
          ? () => read().setMaskAdjustment(
                exposure: 0,
                contrast: 0,
                saturation: 0,
                warmth: 0,
              )
          : null,
      actions: [
        IconButton(
          icon: const Icon(Icons.arrow_back_rounded, size: 19),
          color: AppColors.textSecondary,
          tooltip: 'All masks',
          visualDensity: VisualDensity.compact,
          onPressed: () => read().selectMask(null),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              LrChip(
                label: 'Invert',
                icon: Icons.invert_colors_on_rounded,
                selected: mask.invert,
                onTap: () => read().toggleSelectedMaskInvert(),
              ),
              const SizedBox(width: 8),
              if (mask.type == MaskShapeType.ai)
                LrChip(
                  label: 'Re-select',
                  icon: Icons.refresh_rounded,
                  selected: false,
                  enabled: provider.aiAvailable && !mask.aiPending,
                  onTap: () => read().regenerateAiMask(mask.id),
                ),
            ],
          ),
          if (mask.type == MaskShapeType.luminanceRange) ...[
            LrRangeSlider(
              label: 'Range',
              low: mask.lumLow,
              high: mask.lumHigh,
              // Black-to-white behind the handles, so the track is a
              // legend for the tones being selected.
              trackGradient: AppRamps.luminance,
              defaultLow: 0.0,
              defaultHigh: 0.45,
              onChangeStart: () => read().beginAdjustmentGesture(),
              onChanged: (low, high) =>
                  read().updateMaskLuminanceRange(low: low, high: high),
            ),
            LrSlider(
              label: 'Smoothness',
              value: mask.lumSmoothness * 100,
              min: 0,
              max: 100,
              origin: 25,
              onChangeStart: () => read().beginAdjustmentGesture(),
              onChanged: (v) =>
                  read().updateMaskLuminanceRange(smoothness: v / 100),
            ),
          ],
          if (mask.type == MaskShapeType.colorRange) ...[
            _SampledColorRow(mask: mask),
            LrSlider(
              label: 'Tolerance',
              value: mask.colorTolerance * 100,
              min: 1,
              max: 100,
              origin: 25,
              enabled: mask.colorSampled,
              onChangeStart: () => read().beginAdjustmentGesture(),
              onChanged: (v) => read().updateMaskColorTolerance(v / 100),
            ),
          ],
          if (mask.type == MaskShapeType.radial)
            LrSlider(
              label: 'Feather',
              value: mask.radialFeather * 100,
              min: 5,
              max: 100,
              origin: 50,
              onChangeStart: () => read().beginAdjustmentGesture(),
              onChanged: (v) => read().updateMaskRadial(feather: v / 100),
            ),
          if (mask.type == MaskShapeType.brush)
            LrApplyRow(
              canApply: provider.hasPendingMaskStroke,
              busy: busy,
              onClear: () => read().clearPendingMaskStroke(),
              onApply: () => read().applyMaskBrush(),
            ),
          const LrSectionHeader(label: 'Adjust this area'),
          LrSlider(
            label: 'Exposure',
            value: mask.exposure,
            onChangeStart: () => read().beginAdjustmentGesture(),
            onChanged: (v) => read().setMaskAdjustment(exposure: v),
          ),
          LrSlider(
            label: 'Contrast',
            value: mask.contrast,
            onChangeStart: () => read().beginAdjustmentGesture(),
            onChanged: (v) => read().setMaskAdjustment(contrast: v),
          ),
          LrSlider(
            label: 'Saturation',
            value: mask.saturation,
            onChangeStart: () => read().beginAdjustmentGesture(),
            onChanged: (v) => read().setMaskAdjustment(saturation: v),
          ),
          LrSlider(
            label: 'Warmth',
            value: mask.warmth,
            onChangeStart: () => read().beginAdjustmentGesture(),
            onChanged: (v) => read().setMaskAdjustment(warmth: v),
          ),
        ],
      ),
    );
  }
}
