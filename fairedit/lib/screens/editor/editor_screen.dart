import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/widgets/histogram.dart';
import '../../models/mask_state.dart';
import '../../providers/edit_provider.dart';
import 'widgets/blur_focus_overlay.dart';
import 'widgets/blur_panel.dart';
import 'widgets/color_grade_panel.dart';
import 'widgets/color_sample_overlay.dart';
import 'widgets/crop_overlay.dart';
import 'widgets/crop_panel.dart';
import 'widgets/curves_panel.dart';
import 'widgets/editor_canvas.dart';
import 'widgets/editor_image_stack.dart';
import 'widgets/editor_top_bar.dart';
import 'widgets/effects_panel.dart';
import 'widgets/feature_toolbar.dart';
import 'widgets/heal_brush_overlay.dart';
import 'widgets/heal_panel.dart';
import 'widgets/light_panel.dart';
import 'widgets/mask_brush_overlay.dart';
import 'widgets/mask_gradient_overlay.dart';
import 'widgets/mask_panel.dart';

class EditorScreen extends StatefulWidget {
  final String imagePath;
  final String projectName;

  const EditorScreen({
    super.key,
    required this.imagePath,
    required this.projectName,
  });

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  EditorFeature? _activeFeature;
  bool _showOriginal = false;
  bool _isExiting = false;
  bool _isExporting = false;
  bool _showHistogram = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<EditProvider>().loadFromFile(widget.imagePath);
    });
  }

  void _handleFeatureTap(EditorFeature feature) {
    setState(() {
      final closing = _activeFeature == feature;
      _activeFeature = closing ? null : feature;
      // Leaving Masking with a mask still selected would strand its
      // on-canvas handles with no panel to drive them.
      if (closing || feature != EditorFeature.mask) {
        context.read<EditProvider>().selectMask(null);
      }
    });
  }

  void _closePanel() {
    setState(() {
      _activeFeature = null;
      context.read<EditProvider>().selectMask(null);
    });
    context.read<EditProvider>().saveEdits();
  }

  /// Saves edits, then pops. Uses Navigator.pop() (not maybePop()) because
  /// pop() bypasses the PopScope below — calling maybePop() here would
  /// re-trigger canPop's false gate and never actually leave the screen.
  Future<void> _saveAndPop() async {
    if (_isExiting) return;
    _isExiting = true;
    await context.read<EditProvider>().saveEdits();
    if (mounted) Navigator.of(context).pop();
  }

  /// Renders at full resolution and hands the file to the system share
  /// sheet.
  ///
  /// The temp directory is the right *staging* place — the share sheet
  /// copies the file wherever the user sends it, so nothing depends on
  /// the staged copy surviving. What was wrong before was stopping here
  /// and printing the path: a cache path is unreachable from a phone and
  /// the OS is free to delete it, so "export" produced nothing the user
  /// could actually find.
  Future<void> _export() async {
    final provider = context.read<EditProvider>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isExporting = true);
    try {
      final bytes = await provider.renderFullResolutionPng();
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/${widget.projectName}_${DateTime.now().millisecondsSinceEpoch}.png';
      await File(path).writeAsBytes(bytes);

      if (!mounted) return;
      // iPad anchors the share popover to a rect; without one it throws
      // rather than degrading. The share button sits top-right, so that
      // is where the popover should spring from.
      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null || !box.hasSize
          ? null
          : Rect.fromLTWH(box.size.width - 60, 0, 48, 48);

      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: 'image/png')],
          fileNameOverrides: ['${widget.projectName}.png'],
          subject: widget.projectName,
          sharePositionOrigin: origin,
        ),
      );

      // A dismissed sheet is a decision, not a failure — saying nothing
      // is the correct response to "never mind".
      if (result.status == ShareResultStatus.success) {
        messenger.showSnackBar(const SnackBar(content: Text('Exported')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  /// The on-canvas interaction layer the active tool needs, if any.
  Widget? _overlayFor(EditorFeature? feature, EditProvider provider) {
    switch (feature) {
      case EditorFeature.blur:
        return const BlurInteractionLayer();
      case EditorFeature.crop:
        return const CropInteractionLayer();
      case EditorFeature.heal:
        return const HealBrushOverlay();
      case EditorFeature.mask:
        final selected = provider.selectedMask;
        if (selected == null) return null;
        return switch (selected.type) {
          MaskShapeType.brush => const MaskBrushOverlay(),
          MaskShapeType.colorRange => const ColorSampleOverlay(),
          // Nothing to drag: an AI mask comes from the model, and a
          // luminance range is driven entirely from the panel.
          MaskShapeType.ai || MaskShapeType.luminanceRange => null,
          _ => const MaskGradientOverlay(),
        };
      default:
        return null;
    }
  }

  Widget? _panelFor(EditorFeature? feature) {
    return switch (feature) {
      EditorFeature.light => LightPanel(onClose: _closePanel),
      EditorFeature.curves => CurvesPanel(onClose: _closePanel),
      EditorFeature.colour => ColorGradePanel(onClose: _closePanel),
      EditorFeature.blur => BlurPanel(onClose: _closePanel),
      EditorFeature.effects => EffectsPanel(onClose: _closePanel),
      EditorFeature.crop => CropPanel(onClose: _closePanel),
      EditorFeature.heal => HealPanel(onClose: _closePanel),
      EditorFeature.mask => MaskPanel(onClose: _closePanel),
      null => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final feature = _activeFeature;

    // Crop, Blur, Heal and Masking all drive the photo by dragging on it,
    // so hold-to-compare would otherwise compete with those gestures in
    // the same gesture arena.
    final canvasBusy = feature?.ownsCanvasGestures ?? false;
    final ready = !provider.isLoading && provider.image != null;
    final img = provider.image;

    double? aspectRatio;
    if (img != null) {
      aspectRatio = feature == EditorFeature.crop
          ? provider.editState.crop.preCropAspectRatio(img.width, img.height)
          : provider.editState.crop.outputAspectRatio(img.width, img.height);
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          // Escaping the open panel first matches the mental model of a
          // tool palette: Back closes the tool, Back again leaves.
          if (_activeFeature != null) {
            _closePanel();
          } else {
            _saveAndPop();
          }
        },
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              EditorTopBar(
                title: widget.projectName,
                subtitle: img == null ? null : '${img.width} × ${img.height}',
                onBack: _saveAndPop,
                onUndo: provider.canUndo ? provider.undo : null,
                onRedo: provider.canRedo ? provider.redo : null,
                onExport: ready && !_isExporting ? _export : null,
                exporting: _isExporting,
                histogramVisible: _showHistogram,
                onToggleHistogram: ready
                    ? () => setState(() => _showHistogram = !_showHistogram)
                    : null,
              ),
              // Above the photo rather than inside a panel: a histogram is
              // a reference you glance at *while* dragging a slider, and
              // one buried in a panel is hidden exactly when it matters.
              Expanded(
                child: Container(
                  color: AppColors.canvas,
                  child: _buildCanvasArea(
                    provider: provider,
                    aspectRatio: aspectRatio,
                    canvasBusy: canvasBusy,
                    feature: feature,
                  ),
                ),
              ),
              // AnimatedSize keeps the photo from snapping to a new size
              // the instant a panel appears — it scales into the space
              // that's left over the same 220ms the panel takes to arrive.
              AnimatedSize(
                duration: AppMotion.medium,
                curve: AppMotion.emphasized,
                alignment: Alignment.topCenter,
                child: AnimatedSwitcher(
                  duration: AppMotion.medium,
                  switchInCurve: AppMotion.emphasized,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, 0.06),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.bottomCenter,
                    children: [...previous, if (current != null) current],
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(feature),
                    child: _panelFor(feature) ?? const SizedBox(width: double.infinity),
                  ),
                ),
              ),
              FeatureToolbar(
                selected: feature,
                onSelect: _handleFeatureTap,
                enabled: ready,
              ),
              // Panels carry their own bottom inset; the rail needs the
              // gesture-bar padding added under it.
              Container(
                color: AppColors.background,
                height: MediaQuery.paddingOf(context).bottom,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCanvasArea({
    required EditProvider provider,
    required double? aspectRatio,
    required bool canvasBusy,
    required EditorFeature? feature,
  }) {
    if (provider.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.broken_image_outlined,
                color: AppColors.textTertiary,
                size: 44,
              ),
              const SizedBox(height: 14),
              Text(
                provider.error!,
                style: AppText.control.copyWith(color: AppColors.danger),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final overlay = _overlayFor(feature, provider);

    return Stack(
      children: [
        Positioned.fill(
          child: Center(
            child: Padding(
              // Crop needs the frame inset further so the corner handles
              // have somewhere to live outside the image edge.
              padding: EdgeInsets.all(feature == EditorFeature.crop ? 28 : 14),
              child: InteractiveViewer(
                // Pinch-to-zoom is two-fingered and pan is one-fingered,
                // so disabling pan while a tool owns the canvas leaves
                // one-finger paint/drag to the overlay while two-finger
                // zoom keeps working — which is exactly when you want to
                // zoom, e.g. brushing a mask along a hairline.
                //
                // minScale 1.0 means pinching out always returns to fit,
                // so there is no way to get stuck zoomed in.
                // ponytail: no pan while painting; add a two-finger pan
                // gesture of our own if retouching at high zoom needs it.
                panEnabled: !canvasBusy,
                scaleEnabled: true,
                minScale: 1.0,
                maxScale: 8.0,
                clipBehavior: Clip.none,
                child: _CompareOnHold(
                  enabled: !canvasBusy,
                  onChanged: (v) => setState(() => _showOriginal = v),
                  child: EditorImageStack(
                    aspectRatio: aspectRatio!,
                    overlay: overlay,
                    canvas: EditorCanvas(
                      image: provider.image!,
                      curveLut: _showOriginal
                          ? provider.identityLut!
                          : provider.curveLut!,
                      subjectMask: provider.subjectMaskForShader!,
                      healMask: provider.healMaskForShader!,
                      healedTexture: provider.healedTextureForShader!,
                      maskBrushes: provider.maskBrushesForShader,
                      editState: provider.editState,
                      showOriginal: _showOriginal,
                  cropPreviewFull: feature == EditorFeature.crop,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Overlaid rather than banded above the photo: a histogram is a
        // glance, and on a portrait shot a full-width strip was taking a
        // fifth of the image's height to show it. Opposite corner from
        // Compare so the two never collide.
        if (_showHistogram)
          Positioned(
            right: 14,
            top: 12,
            child: IgnorePointer(
              child: SizedBox(
                width: 132,
                child: Opacity(
                  opacity: 0.9,
                  child: HistogramView(
                    data: provider.histogram,
                    height: 38,
                  ),
                ),
              ),
            ),
          ),
        if (!canvasBusy)
          Positioned(
            left: 14,
            bottom: 12,
            child: CompareButton(
              showingOriginal: _showOriginal,
              hasEdits: provider.hasEdits,
              onHoldChanged: (v) => setState(() => _showOriginal = v),
            ),
          ),
      ],
    );
  }
}

/// Press-and-hold anywhere on the photo to see the original.
///
/// The corner button is the discoverable affordance; this is the one
/// people actually reach for, because holding the image is what every
/// other editor does. Both drive the same flag.
///
/// Uses a raw Listener rather than GestureDetector.onLongPress so it
/// does not enter the gesture arena — InteractiveViewer's scale
/// recognizer would otherwise win the pointer and the hold would never
/// fire.
class _CompareOnHold extends StatefulWidget {
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final Widget child;

  const _CompareOnHold({
    required this.enabled,
    required this.onChanged,
    required this.child,
  });

  @override
  State<_CompareOnHold> createState() => _CompareOnHoldState();
}

class _CompareOnHoldState extends State<_CompareOnHold> {
  Timer? _holdTimer;
  bool _showing = false;
  int _pointers = 0;

  void _down() {
    _pointers++;
    // A second finger means a pinch, not a hold — cancel so zooming
    // never flashes the original.
    if (_pointers > 1) {
      _cancel();
      return;
    }
    _holdTimer = Timer(const Duration(milliseconds: 260), () {
      _showing = true;
      widget.onChanged(true);
    });
  }

  void _up() {
    _pointers = (_pointers - 1).clamp(0, 10);
    _cancel();
  }

  void _cancel() {
    _holdTimer?.cancel();
    _holdTimer = null;
    if (_showing) {
      _showing = false;
      widget.onChanged(false);
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Listener(
      onPointerDown: (_) => _down(),
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
      child: widget.child,
    );
  }
}
