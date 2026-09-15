import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/editor_icons.dart';

/// The editor's tools, in the order they appear on the rail.
///
/// Ordering follows Lightroom's: destructive-framing first (Crop), then
/// tone, then colour, then creative effects, then the local/repair tools
/// last. Users coming from Lightroom reach for position as much as for
/// the label, so the order is part of the interface.
enum EditorFeature { crop, light, colour, curves, effects, blur, heal, mask }

extension EditorFeatureX on EditorFeature {
  String get label => switch (this) {
        EditorFeature.crop => 'Crop',
        EditorFeature.light => 'Light',
        EditorFeature.colour => 'Color',
        EditorFeature.curves => 'Curve',
        EditorFeature.effects => 'Effects',
        EditorFeature.blur => 'Blur',
        EditorFeature.heal => 'Healing',
        EditorFeature.mask => 'Masking',
      };

  /// Title shown in the panel header — room for the fuller name than the
  /// rail caption allows.
  String get panelTitle => switch (this) {
        EditorFeature.crop => 'Crop & Rotate',
        EditorFeature.light => 'Light',
        EditorFeature.colour => 'Color Grading',
        EditorFeature.curves => 'Tone Curve',
        EditorFeature.effects => 'Effects',
        EditorFeature.blur => 'Lens Blur',
        EditorFeature.heal => 'Healing',
        EditorFeature.mask => 'Masking',
      };

  /// The app's own glyph, not a Material stock icon — see
  /// [EditorGlyph] for why the set is hand-drawn.
  EditorGlyph get glyph => switch (this) {
        EditorFeature.crop => EditorGlyph.crop,
        EditorFeature.light => EditorGlyph.light,
        EditorFeature.colour => EditorGlyph.colorGrade,
        EditorFeature.curves => EditorGlyph.curve,
        EditorFeature.effects => EditorGlyph.effects,
        EditorFeature.blur => EditorGlyph.lensBlur,
        EditorFeature.heal => EditorGlyph.healing,
        EditorFeature.mask => EditorGlyph.masking,
      };

  /// Tools that take over touch input on the photo itself, so the editor
  /// knows to disable hold-to-compare while they are open.
  bool get ownsCanvasGestures =>
      this == EditorFeature.crop ||
      this == EditorFeature.blur ||
      this == EditorFeature.heal ||
      this == EditorFeature.mask;
}

/// Bottom tool rail. Scrolls horizontally, keeps the selected tool
/// scrolled into view, and marks the active tool with an accent glyph
/// plus a top indicator rather than a filled pill — the pill read as a
/// button the user had to press again to leave.
class FeatureToolbar extends StatefulWidget {
  final EditorFeature? selected;
  final ValueChanged<EditorFeature> onSelect;

  /// Dims and blocks the rail while the image is still loading.
  final bool enabled;

  const FeatureToolbar({
    super.key,
    required this.selected,
    required this.onSelect,
    this.enabled = true,
  });

  @override
  State<FeatureToolbar> createState() => _FeatureToolbarState();
}

class _FeatureToolbarState extends State<FeatureToolbar> {
  final _controller = ScrollController();
  final _keys = {
    for (final f in EditorFeature.values) f: GlobalKey(),
  };

  @override
  void didUpdateWidget(FeatureToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected && widget.selected != null) {
      _revealSelected();
    }
  }

  /// Scrolls the active tool fully into view. Without this, selecting a
  /// tool near the edge of the rail leaves its panel open while its own
  /// rail item is half off-screen, which reads as a broken selection.
  void _revealSelected() {
    final key = _keys[widget.selected];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: AppMotion.medium,
      curve: AppMotion.emphasized,
      alignment: 0.5,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AppLayout.toolRailHeight,
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: AnimatedOpacity(
        duration: AppMotion.fast,
        opacity: widget.enabled ? 1 : 0.35,
        child: IgnorePointer(
          ignoring: !widget.enabled,
          child: ListView.builder(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: EditorFeature.values.length,
            itemBuilder: (context, index) {
              final feature = EditorFeature.values[index];
              return _ToolButton(
                key: _keys[feature],
                feature: feature,
                selected: feature == widget.selected,
                onTap: () {
                  HapticFeedback.selectionClick();
                  widget.onSelect(feature);
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final EditorFeature feature;
  final bool selected;
  final VoidCallback onTap;

  const _ToolButton({
    super.key,
    required this.feature,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.accent : AppColors.textSecondary;

    return Semantics(
      button: true,
      selected: selected,
      label: feature.panelTitle,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppLayout.radiusMd),
        child: SizedBox(
          width: 66,
          child: Stack(
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  EditorIcon(
                    feature.glyph,
                    size: 23,
                    color: fg,
                    strokeScale: selected ? 1.15 : 1,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    feature.label,
                    style: AppText.caption.copyWith(
                      color: fg,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
              // Active indicator, aligned to the rail's top border so it
              // reads as a tab connected to the panel above it.
              Positioned(
                top: 0,
                left: 20,
                right: 20,
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  height: 2,
                  decoration: BoxDecoration(
                    color: selected ? AppColors.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
