import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_shaders/flutter_shaders.dart';

import '../../../models/edit_state.dart';
import '../../../services/image_processing/shader_engine.dart';

/// Shows [image] with [editState] applied in real time, using
/// AnimatedSampler so the fragment shader samples the widget's actual
/// on-screen raster (correct on any device pixel ratio).
///
/// Deliberately does NOT wrap itself in an AspectRatio — the caller does
/// that (see EditorImageStack), so that an interaction overlay drawn on
/// top can share the exact same sized box as the image itself.
class EditorCanvas extends StatelessWidget {
  final ui.Image image;
  final ui.Image curveLut;
  final ui.Image subjectMask;
  final ui.Image healMask;
  final ui.Image healedTexture;
  final List<ui.Image> maskBrushes;
  final EditState editState;
  final bool showOriginal;
  /// When true, renders as if crop's left/top/right/bottom were 0/0/1/1 —
  /// showing the full straightened+rotated+flipped frame with nothing
  /// cropped away yet. Used by the crop editing UI, which needs to show
  /// the whole frame so the user can position the crop rect within it.
  final bool cropPreviewFull;

  const EditorCanvas({
    super.key,
    required this.image,
    required this.curveLut,
    required this.subjectMask,
    required this.healMask,
    required this.healedTexture,
    required this.maskBrushes,
    required this.editState,
    this.showOriginal = false,
    this.cropPreviewFull = false,
  });

  @override
  Widget build(BuildContext context) {
    var effectiveState = showOriginal ? const EditState() : editState;
    if (cropPreviewFull && !effectiveState.crop.isNeutral) {
      effectiveState = effectiveState.copyWith(
        crop: effectiveState.crop.copyWith(left: 0, top: 0, right: 1, bottom: 1),
      );
    }

    return AnimatedSampler(
      (ui.Image rasterImage, Size size, Canvas canvas) {
        if (!ShaderEngine.instance.isLoaded) {
          canvas.drawImageRect(
            rasterImage,
            Rect.fromLTWH(
              0,
              0,
              rasterImage.width.toDouble(),
              rasterImage.height.toDouble(),
            ),
            Rect.fromLTWH(0, 0, size.width, size.height),
            Paint(),
          );
          return;
        }
        final shader = ShaderEngine.instance.buildShader(
          image: rasterImage,
          curveLut: curveLut,
          subjectMask: subjectMask,
          healMask: healMask,
          healedTexture: healedTexture,
          maskBrushes: maskBrushes,
          width: size.width,
          height: size.height,
          state: effectiveState,
          reuse: true,
        );
        canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
      },
      child: RawImage(image: image, fit: BoxFit.fill),
    );
  }
}
