import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/editor_icons.dart';
import '../../../core/widgets/lr_panel.dart';
import '../../../core/widgets/lr_slider.dart';
import '../../../providers/edit_provider.dart';
import 'feature_toolbar.dart';

/// Healing — paint over something, then commit.
///
/// The panel offers two engines behind one brush: the on-device
/// diffusion fill, which is instant and good for blemishes and small
/// spots, and the server-side LaMa inpaint, which handles whole objects
/// on busy backgrounds. Choosing between them is a real decision the
/// user has to make (latency and network vs. quality), so it is a
/// visible segmented control rather than a hidden heuristic.
class HealPanel extends StatelessWidget {
  final VoidCallback onClose;

  const HealPanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final heal = provider.editState.heal;
    final read = context.read<EditProvider>;
    final hasPending = provider.hasPendingHealStroke;
    final busy = provider.isApplyingHeal;
    final canReset = !(heal.isNeutral && !hasPending);

    return LrPanel(
      title: EditorFeature.heal.panelTitle,
      icon: EditorFeature.heal.glyph,
      onDone: onClose,
      onReset: (!canReset || busy) ? null : () => read().resetHeal(),
      busy: busy,
      error: provider.healError,
      hint: hasPending
          ? 'Tap Apply to fill the painted area'
          : 'Paint over a blemish or unwanted object',
      maxHeight: 230,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _EngineSelector(
            useAi: provider.useAiRemove,
            aiAvailable: provider.aiAvailable,
            onChanged: (v) => read().setUseAiRemove(v),
          ),
          LrSlider(
            label: 'Brush Size',
            value: heal.brushSize,
            min: 5,
            max: 100,
            enabled: !busy,
            onChangeStart: () => read().beginAdjustmentGesture(),
            onChanged: (v) => read().updateHealBrushSize(v),
          ),
          LrApplyRow(
            canApply: hasPending,
            busy: busy,
            onClear: () => read().clearPendingHealStroke(),
            onApply: () => read().applyHeal(),
            applyLabel: provider.useAiRemove ? 'AI Remove' : 'Heal',
          ),
        ],
      ),
    );
  }
}

class _EngineSelector extends StatelessWidget {
  final bool useAi;
  final bool aiAvailable;
  final ValueChanged<bool> onChanged;

  const _EngineSelector({
    required this.useAi,
    required this.aiAvailable,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: _EngineOption(
              glyph: EditorGlyph.healing,
              title: 'Spot Heal',
              caption: 'On device · instant',
              selected: !useAi,
              enabled: true,
              onTap: () => onChanged(false),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _EngineOption(
              glyph: EditorGlyph.effects,
              title: 'AI Remove',
              caption: aiAvailable ? 'LaMa · best quality' : 'Server offline',
              selected: useAi,
              enabled: aiAvailable,
              onTap: () => onChanged(true),
            ),
          ),
        ],
      ),
    );
  }
}

class _EngineOption extends StatelessWidget {
  final EditorGlyph glyph;
  final String title;
  final String caption;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _EngineOption({
    required this.glyph,
    required this.title,
    required this.caption,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = !enabled
        ? AppColors.textDisabled
        : selected
            ? AppColors.accent
            : AppColors.textPrimary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppLayout.radiusMd),
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentSubtle : AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(AppLayout.radiusMd),
            border: Border.all(
              color: selected ? AppColors.accent : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              EditorIcon(glyph, size: 18, color: fg),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: AppText.chip.copyWith(color: fg)),
                    const SizedBox(height: 1),
                    Text(
                      caption,
                      style: AppText.hint,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
