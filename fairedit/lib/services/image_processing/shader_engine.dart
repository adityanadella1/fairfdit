import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../models/edit_state.dart';
import '../../models/mask_state.dart';

/// Loads and manages the single fragment shader used to preview and
/// render every non-destructive edit. Adjustments, Curves, Color Grading,
/// Blur, Effects, and Crop all use it today; future features add more
/// uniforms to the same shader as they're built, so everything composes
/// in one GPU pass.
class ShaderEngine {
  ShaderEngine._();
  static final ShaderEngine instance = ShaderEngine._();

  ui.FragmentProgram? _program;
  Future<void>? _loadingFuture;
  ui.Image? _identityLut;
  ui.Image? _neutralMask;

  /// The live-preview shader, reused frame to frame instead of allocated
  /// fresh. EditorCanvas calls buildShader() on every repaint — up to
  /// 120x/sec while dragging — and `FragmentProgram.fragmentShader()`
  /// allocates a native object each time; never disposing those piled up
  /// undisposed native shaders faster than GC finalizers could clear them,
  /// which is what made dragging feel laggy. Reusing one instance and just
  /// re-setting its uniforms (the API's intended per-frame usage) fixes it.
  ui.FragmentShader? _previewShader;

  bool get isLoaded => _program != null;

  Future<void> ensureLoaded() {
    if (_program != null) return Future.value();
    return _loadingFuture ??= _load();
  }

  Future<void> _load() async {
    _program = await ui.FragmentProgram.fromAsset('shaders/edit_shader.frag');
  }

  /// A cached 256x1 "no change" curve LUT (output = input for every
  /// channel), shared app-wide — used for the "hold to compare" original
  /// preview, so it's correct even when the user has edited curves.
  Future<ui.Image> ensureIdentityLut() async {
    final cached = _identityLut;
    if (cached != null) return cached;
    final bytes = Uint8List(256 * 4);
    for (var i = 0; i < 256; i++) {
      bytes[i * 4 + 0] = i;
      bytes[i * 4 + 1] = i;
      bytes[i * 4 + 2] = i;
      bytes[i * 4 + 3] = 255;
    }
    final image = await decodePixels(bytes, 256, 1);
    _identityLut = image;
    return image;
  }

  /// A tiny (2x2), all-zero placeholder — shared by every "optional mask"
  /// sampler (uSubjectMask before Select Subject has run, uHealMask/
  /// uHealedTexture before Heal has been applied). Each of those blends
  /// use this mask value as their strength, so an all-zero placeholder is
  /// a correct, cheap no-op regardless of which one it's standing in for.
  Future<ui.Image> ensureNeutralMask() async {
    final cached = _neutralMask;
    if (cached != null) return cached;
    final bytes = Uint8List(2 * 2 * 4); // all zeros
    final image = await decodePixels(bytes, 2, 2);
    _neutralMask = image;
    return image;
  }

  /// Decodes an RGBA byte buffer of the given dimensions into an image
  /// usable as a shader sampler.
  Future<ui.Image> decodePixels(Uint8List rgbaBytes, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgbaBytes,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  ui.FragmentShader buildShader({
    required ui.Image image,
    required ui.Image curveLut,
    required ui.Image subjectMask,
    required ui.Image healMask,
    required ui.Image healedTexture,
    required List<ui.Image> maskBrushes,
    required double width,
    required double height,
    required EditState state,
    /// True for the live on-screen preview: reuses one persistent shader
    /// instance instead of allocating a new one per call. Offscreen
    /// renders (histogram sampling, export) must NOT set this — they run
    /// async and can overlap a live preview frame that's actively
    /// re-setting the reused instance's uniforms mid-flight, so they keep
    /// allocating (and should dispose) their own.
    bool reuse = false,
  }) {
    final program = _program;
    if (program == null) {
      throw StateError('ShaderEngine.ensureLoaded() must complete before use.');
    }
    if (maskBrushes.length != MaskingState.maxSlots) {
      throw ArgumentError(
        'maskBrushes must have exactly ${MaskingState.maxSlots} entries '
        '(one per mask slot).',
      );
    }
    final shader = reuse ? (_previewShader ??= program.fragmentShader()) : program.fragmentShader();
    var i = 0;
    shader.setFloat(i++, width);
    shader.setFloat(i++, height);
    shader.setFloat(i++, image.width / image.height);
    for (final v in state.toUniformList()) {
      shader.setFloat(i++, v);
    }
    shader.setImageSampler(0, image);
    shader.setImageSampler(1, curveLut);
    shader.setImageSampler(2, subjectMask);
    shader.setImageSampler(3, healMask);
    shader.setImageSampler(4, healedTexture);
    // Slots follow the five fixed samplers above, in the same order the
    // shader declares them.
    for (var slot = 0; slot < MaskingState.maxSlots; slot++) {
      shader.setImageSampler(5 + slot, maskBrushes[slot]);
    }
    return shader;
  }
}
