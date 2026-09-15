import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Canvas, Paint, Colors, Offset, Rect, Size;

/// Runs the iterative diffusion inpainting used by the Heal tool, and
/// renders brush strokes into a mask image. Kept separate from
/// ShaderEngine since this is a genuinely different kind of operation —
/// many small render passes feeding into each other, rather than one
/// shader draw per frame.
class HealEngine {
  HealEngine._();
  static final HealEngine instance = HealEngine._();

  ui.FragmentProgram? _diffusionProgram;

  Future<void> _ensureLoaded() async {
    _diffusionProgram ??= await ui.FragmentProgram.fromAsset('shaders/heal_diffusion.frag');
  }

  /// Renders [normalizedPoints] (0..1 fractions of the target size) as
  /// filled white circles of [brushSizeFraction] (as a fraction of the
  /// smaller dimension) onto a copy of [existingMask] (or a black canvas
  /// if there isn't one yet) — additive, so repeated calls build up a
  /// union of every stroke ever painted rather than replacing it.
  Future<ui.Image> renderMask({
    required List<Offset> normalizedPoints,
    required double brushSizeFraction,
    required int width,
    required int height,
    ui.Image? existingMask,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = Size(width.toDouble(), height.toDouble());

    if (existingMask != null) {
      canvas.drawImageRect(
        existingMask,
        Rect.fromLTWH(0, 0, existingMask.width.toDouble(), existingMask.height.toDouble()),
        Offset.zero & size,
        Paint(),
      );
    } else {
      canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    }

    final minDim = math.min(width, height);
    final radius = brushSizeFraction * minDim * 0.5;
    final brushPaint = Paint()..color = Colors.white;
    for (final p in normalizedPoints) {
      canvas.drawCircle(Offset(p.dx * width, p.dy * height), radius, brushPaint);
    }

    final picture = recorder.endRecording();
    return picture.toImage(width, height);
  }

  /// Fills the masked region of [source] via repeated Jacobi diffusion
  /// (see heal_diffusion.frag) — each pass replaces every masked pixel
  /// with the average of its neighbors from the previous pass, converging
  /// toward a smooth fill. Runs at a capped working resolution regardless
  /// of the source photo's actual size, for speed; the result is used as
  /// a normal UV-sampled texture afterward, so resolution independence
  /// carries through same as the curve LUT / subject mask.
  Future<ui.Image> diffuseInpaint({
    required ui.Image source,
    required ui.Image mask,
    int workingSize = 900,
    int iterations = 80,
  }) async {
    await _ensureLoaded();
    final program = _diffusionProgram!;

    final longSide = math.max(source.width, source.height);
    final scale = longSide > workingSize ? workingSize / longSide : 1.0;
    final w = (source.width * scale).round().clamp(1, source.width);
    final h = (source.height * scale).round().clamp(1, source.height);

    ui.Image current = source;
    for (var i = 0; i < iterations; i++) {
      final shader = program.fragmentShader();
      shader.setFloat(0, w.toDouble());
      shader.setFloat(1, h.toDouble());
      shader.setImageSampler(0, current);
      shader.setImageSampler(1, mask);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final size = Size(w.toDouble(), h.toDouble());
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
      final picture = recorder.endRecording();
      final next = await picture.toImage(w, h);

      if (!identical(current, source)) {
        current.dispose();
      }
      current = next;
    }

    return current;
  }
}
