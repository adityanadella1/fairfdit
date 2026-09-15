import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import 'editor_icons.dart';

/// The shared chrome every editing panel sits inside.
///
/// Before this existed each tool bar drew its own `Container(color:)` with
/// its own padding, header layout and Reset/Done placement, so the
/// controls visibly shifted as you moved between tools. Centralising the
/// shell means switching tools only changes the *contents* of the panel —
/// the frame around them stays put, which is what makes a tool palette
/// feel like one instrument instead of eight screens.
class LrPanel extends StatelessWidget {
  final String title;
  final EditorGlyph icon;

  /// Panel body. Scrolls internally when it exceeds [maxHeight].
  final Widget child;

  /// Extra controls in the header, to the left of Reset/Done.
  final List<Widget> actions;

  /// Enabled only when there is something to reset. Null hides the button.
  final VoidCallback? onReset;

  /// Confirm-and-close. Always shown — it is the panel's primary exit.
  final VoidCallback onDone;

  /// Helper line pinned under the body, e.g. "Drag on the photo to crop".
  final String? hint;

  /// Error line shown above the hint, in the danger colour.
  final String? error;

  /// Caps the body so a long panel can never eat the photo. The photo
  /// area shrinks to fit whatever is left, and the body scrolls.
  final double maxHeight;

  /// Set while a long-running operation is in flight — dims the body and
  /// blocks input rather than letting the user keep editing values that
  /// the in-flight job has already snapshotted.
  final bool busy;

  const LrPanel({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    required this.onDone,
    this.actions = const [],
    this.onReset,
    this.hint,
    this.error,
    this.maxHeight = 300,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final canReset = onReset != null;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PanelHeader(
            title: title,
            icon: icon,
            actions: actions,
            onReset: canReset ? onReset : null,
            onDone: busy ? null : onDone,
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: AnimatedOpacity(
              duration: AppMotion.fast,
              opacity: busy ? 0.45 : 1,
              child: IgnorePointer(
                ignoring: busy,
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(
                    AppLayout.gutter,
                    4,
                    AppLayout.gutter,
                    8,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
          if (error != null)
            _PanelFooterText(text: error!, color: AppColors.danger)
          else if (hint != null)
            _PanelFooterText(text: hint!, color: AppColors.textTertiary),
          SizedBox(height: MediaQuery.paddingOf(context).bottom > 0 ? 4 : 8),
        ],
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  final String title;
  final EditorGlyph icon;
  final List<Widget> actions;
  final VoidCallback? onReset;
  final VoidCallback? onDone;

  const _PanelHeader({
    required this.title,
    required this.icon,
    required this.actions,
    required this.onReset,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.only(left: AppLayout.gutter, right: 4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          EditorIcon(icon, size: 16, color: AppColors.accent),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              title.toUpperCase(),
              style: AppText.panelTitle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Spacer(),
          ...actions,
          if (onReset != null)
            TextButton(onPressed: onReset, child: const Text('Reset'))
          else
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('Reset', style: AppText.chip),
            ),
          IconButton(
            icon: const Icon(Icons.check_rounded, size: 22),
            color: AppColors.accent,
            disabledColor: AppColors.textDisabled,
            tooltip: 'Done',
            onPressed: onDone,
          ),
        ],
      ),
    );
  }
}

class _PanelFooterText extends StatelessWidget {
  final String text;
  final Color color;

  const _PanelFooterText({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppLayout.gutter, 0, AppLayout.gutter, 4),
      child: SizedBox(
        width: double.infinity,
        child: Text(
          text,
          style: AppText.hint.copyWith(color: color),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// Group heading inside a scrolling panel ("LIGHT", "COLOR", "DETAIL").
class LrSectionHeader extends StatelessWidget {
  final String label;

  /// Optional trailing control, e.g. a per-section reset or Auto button.
  final Widget? trailing;

  /// Adds breathing room above. Off for the first section in a panel.
  final bool topSpacing;

  const LrSectionHeader({
    super.key,
    required this.label,
    this.trailing,
    this.topSpacing = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: topSpacing ? 14 : 2, bottom: 2),
      child: Row(
        children: [
          Text(label.toUpperCase(), style: AppText.sectionLabel),
          const SizedBox(width: 10),
          const Expanded(child: Divider(color: AppColors.divider)),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}

/// Selectable pill, used for aspect presets, bokeh shapes, mask kinds.
class LrChip extends StatelessWidget {
  final String label;
  final IconData? icon;

  /// Preferred over [icon] — the app's own glyph set.
  final EditorGlyph? glyph;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const LrChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.glyph,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final fg = !enabled
        ? AppColors.textDisabled
        : selected
            ? AppColors.accent
            : AppColors.textSecondary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppLayout.radiusSm),
        child: AnimatedContainer(
          duration: AppMotion.fast,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentSubtle : AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(AppLayout.radiusSm),
            border: Border.all(
              color: selected ? AppColors.accent : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (glyph != null) ...[
                EditorIcon(glyph!, size: 15, color: fg),
                const SizedBox(width: 6),
              ] else if (icon != null) ...[
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 6),
              ],
              Text(label, style: AppText.chip.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontally scrolling row of [LrChip]s with consistent spacing and
/// edge padding that lines up with the panel gutter.
class LrChipRow extends StatelessWidget {
  final List<Widget> children;

  const LrChipRow({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: children.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => children[i],
      ),
    );
  }
}

/// Square icon button used for discrete actions inside a panel
/// (rotate, flip, invert…), with a selected state.
class LrIconToggle extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  /// Rotates the glyph, so one icon can serve both axes of a flip pair.
  final double turns;

  const LrIconToggle({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
    this.enabled = true,
    this.turns = 0,
  });

  @override
  Widget build(BuildContext context) {
    final fg = !enabled
        ? AppColors.textDisabled
        : selected
            ? AppColors.accent
            : AppColors.textSecondary;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(AppLayout.radiusSm),
          child: AnimatedContainer(
            duration: AppMotion.fast,
            width: 40,
            height: 36,
            decoration: BoxDecoration(
              color: selected ? AppColors.accentSubtle : Colors.transparent,
              borderRadius: BorderRadius.circular(AppLayout.radiusSm),
            ),
            child: RotatedBox(
              quarterTurns: (turns * 4).round(),
              child: Icon(icon, size: 19, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Clear / Apply pair shared by the brush-driven tools (Heal, and the
/// brush mask editor), so "paint then commit" reads identically in both.
class LrApplyRow extends StatelessWidget {
  final bool canApply;
  final bool busy;
  final VoidCallback onClear;
  final VoidCallback onApply;
  final String applyLabel;

  const LrApplyRow({
    super.key,
    required this.canApply,
    required this.busy,
    required this.onClear,
    required this.onApply,
    this.applyLabel = 'Apply',
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: (!canApply || busy) ? null : onClear,
              child: const Text('Clear'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: (!canApply || busy) ? null : onApply,
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(applyLabel),
            ),
          ),
        ],
      ),
    );
  }
}
