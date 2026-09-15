import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/editor_icons.dart';

/// The editor's top chrome.
///
/// A hand-built bar rather than an [AppBar] so the height stays fixed at
/// 48 regardless of the actions in it, and so the title can shrink to the
/// centre slot without pushing the undo/redo pair around as the project
/// name changes length.
class EditorTopBar extends StatelessWidget {
  final String title;

  /// Second line under the title, e.g. image dimensions. Hidden when null.
  final String? subtitle;

  final VoidCallback onBack;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onExport;

  /// True while a full-resolution export is rendering.
  final bool exporting;

  /// Histogram visibility, toggled from the bar. On a phone the readout
  /// costs real canvas height, so it is the user's call rather than
  /// always-on.
  final bool histogramVisible;
  final VoidCallback? onToggleHistogram;

  const EditorTopBar({
    super.key,
    required this.title,
    required this.onBack,
    this.subtitle,
    this.onUndo,
    this.onRedo,
    this.onExport,
    this.exporting = false,
    this.histogramVisible = true,
    this.onToggleHistogram,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          // The one Material glyph kept on purpose: a back chevron is a
          // platform convention, not app identity, and drawing our own
          // would only make it subtly wrong.
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
            color: AppColors.textPrimary,
            tooltip: 'Back to library',
            onPressed: onBack,
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: AppText.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: AppText.hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          _BarButton(
            glyph: EditorGlyph.histogram,
            tooltip: histogramVisible ? 'Hide histogram' : 'Show histogram',
            onPressed: onToggleHistogram,
            active: histogramVisible,
          ),
          _BarButton(
            glyph: EditorGlyph.undo,
            tooltip: 'Undo',
            onPressed: onUndo,
          ),
          _BarButton(
            glyph: EditorGlyph.redo,
            tooltip: 'Redo',
            onPressed: onRedo,
          ),
          if (exporting)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            _BarButton(
              glyph: EditorGlyph.export,
              tooltip: 'Export',
              onPressed: onExport,
              accent: true,
            ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  final EditorGlyph glyph;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool accent;

  /// Toggle buttons tint accent while on, so the bar shows state rather
  /// than only offering actions.
  final bool active;

  const _BarButton({
    required this.glyph,
    required this.tooltip,
    required this.onPressed,
    this.accent = false,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final color = !enabled
        ? AppColors.textDisabled
        : (accent || active)
            ? AppColors.accent
            : AppColors.textPrimary;

    return IconButton(
      icon: EditorIcon(glyph, size: 19, color: color),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Floating "hold to see the original" control, overlaid on the canvas.
///
/// Lightroom puts compare on the photo rather than in a panel because it
/// is the one action you want while *looking at* the image — reaching
/// into a menu to check your work breaks the comparison you were making.
class CompareButton extends StatelessWidget {
  final bool showingOriginal;
  final bool hasEdits;
  final ValueChanged<bool> onHoldChanged;

  const CompareButton({
    super.key,
    required this.showingOriginal,
    required this.hasEdits,
    required this.onHoldChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => onHoldChanged(true),
      onTapUp: (_) => onHoldChanged(false),
      onTapCancel: () => onHoldChanged(false),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: showingOriginal
              ? AppColors.accent
              : Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: showingOriginal ? AppColors.accent : AppColors.divider,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const EditorIcon(
              EditorGlyph.compare,
              size: 15,
              color: Colors.white,
            ),
            const SizedBox(width: 6),
            Text(
              showingOriginal ? 'Original' : (hasEdits ? 'Edited' : 'Original'),
              style: AppText.chip.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
