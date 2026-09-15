import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/blur_state.dart';
import '../models/color_grade_state.dart';
import '../models/crop_state.dart';
import '../models/curves_state.dart';
import '../models/edit_state.dart';
import '../models/effects_state.dart';
import '../models/heal_state.dart';
import '../models/mask_state.dart';
import '../services/image_processing/coordinate_transform.dart';
import '../services/image_processing/curve_math.dart';
import '../services/image_processing/heal_engine.dart';
import '../core/widgets/histogram.dart';
import '../services/ai/ai_config.dart';
import '../services/ai/ai_service.dart';
import '../services/image_processing/shader_engine.dart';
import '../services/subject_segmentation_service.dart';

/// App-wide singleton representing the photo currently being edited.
/// Kept at the app root (see app.dart) rather than scoped to the editor
/// route, so bottom sheets / dialogs opened from the editor can read it.
class EditProvider extends ChangeNotifier {
  ui.Image? _image;
  String? _imagePath;
  EditState _editState = const EditState();
  bool _isLoading = true;
  String? _error;
  String? _projectDir;

  ui.Image? _curveLut;
  ui.Image? _identityLut;
  int _lutGeneration = 0;

  ui.Image? _subjectMask;
  ui.Image? _neutralMask;
  bool _isDetectingSubject = false;
  String? _subjectDetectionError;

  ui.Image? _healMask;
  ui.Image? _healedTexture;
  final List<Offset> _healStrokePoints = []; // transient, normalized 0..1, not persisted
  bool _isApplyingHeal = false;
  String? _healError;

  /// Whether the AI backend answered its last health probe. Drives
  /// whether AI selection / AI Remove are offered at all, so the user is
  /// never handed a button that can only fail.
  bool _aiAvailable = false;
  bool _useAiRemove = false;
  String? _aiMaskError;

  final Map<String, ui.Image> _maskBrushImages = {}; // keyed by MaskSlot.id
  String? _selectedMaskId; // transient — which mask the UI is currently editing
  final List<Offset> _maskStrokePoints = []; // transient, normalized 0..1, not persisted
  bool _isApplyingMaskBrush = false;
  static const _uuid = Uuid();

  HistogramData _histogram = HistogramData.empty;
  Timer? _histogramTimer;
  int? _histogramSignature;
  bool _isBuildingHistogram = false;

  final List<EditState> _undoStack = [];
  final List<EditState> _redoStack = [];

  ui.Image? get image => _image;
  EditState get editState => _editState;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  bool get hasEdits => _editState.hasAnyEdits;
  bool get isDetectingSubject => _isDetectingSubject;
  String? get subjectDetectionError => _subjectDetectionError;

  /// The current tone-curve LUT, reflecting live curve edits. Non-null
  /// once loading finishes.
  ui.Image? get curveLut => _curveLut;

  /// A "no change" curve LUT, for the hold-to-compare original preview —
  /// correct even when curves have actually been edited. Non-null once
  /// loading finishes.
  ui.Image? get identityLut => _identityLut;

  /// The on-device subject-segmentation mask, once "Select Subject" has
  /// been run — otherwise a harmless placeholder, never null once loaded.
  ui.Image? get subjectMaskForShader => _subjectMask ?? _neutralMask;

  /// The heal brush mask / diffused fill, once anything has been healed —
  /// otherwise a harmless all-zero placeholder for both (a zero mask
  /// makes the healed texture's content irrelevant).
  ui.Image? get healMaskForShader => _healMask ?? _neutralMask;
  ui.Image? get healedTextureForShader => _healedTexture ?? _neutralMask;

  /// Points painted since the last Apply (or since Heal was opened) — not
  /// yet baked into the persisted heal mask. Normalized 0..1.
  List<Offset> get healStrokePoints => List.unmodifiable(_healStrokePoints);
  bool get hasPendingHealStroke => _healStrokePoints.isNotEmpty;
  bool get isApplyingHeal => _isApplyingHeal;
  String? get healError => _healError;

  /// Tonal distribution of the current edit. Recomputed on a debounce
  /// after any change, so it trails a slider drag by a beat rather than
  /// costing a render per frame.
  HistogramData get histogram => _histogram;

  bool get aiAvailable => _aiAvailable;
  bool get useAiRemove => _useAiRemove && _aiAvailable;
  String? get aiMaskError => _aiMaskError;

  String? get selectedMaskId => _selectedMaskId;

  MaskSlot? get selectedMask {
    final id = _selectedMaskId;
    if (id == null) return null;
    for (final slot in _editState.masking.slots) {
      if (slot.id == id) return slot;
    }
    return null;
  }

  List<Offset> get maskStrokePoints => List.unmodifiable(_maskStrokePoints);
  bool get hasPendingMaskStroke => _maskStrokePoints.isNotEmpty;
  bool get isApplyingMaskBrush => _isApplyingMaskBrush;

  /// One coverage texture per mask slot, in slot order, padded with the
  /// neutral placeholder for slots that don't exist or aren't
  /// texture-backed.
  List<ui.Image> get maskBrushesForShader {
    final neutral = _neutralMask!;
    return List.generate(MaskingState.maxSlots, (i) {
      final slots = _editState.masking.slots;
      if (i >= slots.length) return neutral;
      final slot = slots[i];
      if (!slot.isTextureBacked) return neutral;
      return _maskBrushImages[slot.id] ?? neutral;
    });
  }

  Future<void> loadFromFile(String path) async {
    _isLoading = true;
    _error = null;
    _subjectDetectionError = null;
    _healError = null;
    _healStrokePoints.clear();
    _maskStrokePoints.clear();
    _selectedMaskId = null;
    notifyListeners();
    try {
      await ShaderEngine.instance.ensureLoaded();
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      _image?.dispose();
      _image = frame.image;
      _imagePath = path;
      _projectDir = p.dirname(path);
      _editState = await _loadSavedEditState() ?? const EditState();
      _undoStack.clear();
      _redoStack.clear();
      _identityLut = await ShaderEngine.instance.ensureIdentityLut();
      _neutralMask = await ShaderEngine.instance.ensureNeutralMask();
      _subjectMask?.dispose();
      _subjectMask = await _loadSavedImage('subject_mask.png');
      _healMask?.dispose();
      _healMask = await _loadSavedImage('heal_mask.png');
      _healedTexture?.dispose();
      _healedTexture = await _loadSavedImage('heal_result.png');
      for (final img in _maskBrushImages.values) {
        img.dispose();
      }
      _maskBrushImages.clear();
      _samplePixels = null;
      _sampleSignature = null;
      for (final slot in _editState.masking.slots) {
        if (slot.isTextureBacked) {
          final img = await _loadSavedImage('mask_brush_${slot.id}.png');
          if (img != null) _maskBrushImages[slot.id] = img;
        }
      }
      await _regenerateCurveLut();
      // Probed without awaiting: the editor must be usable immediately,
      // and every AI affordance already renders a disabled state until
      // this lands.
      unawaited(refreshAiAvailability());
    } catch (e) {
      _error = 'Could not load image: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<EditState?> _loadSavedEditState() async {
    final dir = _projectDir;
    if (dir == null) return null;
    final file = File(p.join(dir, 'edit_state.json'));
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      return EditState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<ui.Image?> _loadSavedImage(String filename) async {
    final dir = _projectDir;
    if (dir == null) return null;
    final file = File(p.join(dir, filename));
    if (!await file.exists()) return null;
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  /// Persists the current edit values plus a downscaled rendered preview,
  /// so the home screen can show the edited photo and reopening this
  /// project restores exactly where the user left off. Safe to call
  /// often — failures here are non-fatal (the app just falls back to
  /// showing the original / a neutral edit).
  Future<void> saveEdits() async {
    final dir = _projectDir;
    if (dir == null || _image == null) return;
    try {
      final stateFile = File(p.join(dir, 'edit_state.json'));
      await stateFile.writeAsString(jsonEncode(_editState.toJson()));

      final thumbBytes = await _renderPngAtMaxDimension(480);
      final thumbFile = File(p.join(dir, 'preview.png'));
      await thumbFile.writeAsBytes(thumbBytes);
    } catch (_) {
      // Non-fatal.
    }
  }

  void setAdjustment(AdjustmentType type, double value) {
    if (type.valueOf(_editState) == value) return;
    _editState = type.apply(_editState, value);
    notifyListeners();
  }

  /// Call once when a drag gesture starts (a slider, or a curve point),
  /// so the value right before the drag becomes the undo point — not
  /// every intermediate frame.
  void beginAdjustmentGesture() {
    _undoStack.add(_editState);
    _redoStack.clear();
  }

  void resetAdjustments() {
    if (_editState.isAdjustmentsNeutral) return;
    _undoStack.add(_editState);
    _redoStack.clear();
    _editState = _editState.copyWith(
      exposure: 0,
      contrast: 0,
      highlights: 0,
      shadows: 0,
      whites: 0,
      blacks: 0,
      brightness: 0,
      saturation: 0,
      vibrance: 0,
      warmth: 0,
      tint: 0,
    );
    notifyListeners();
  }

  // --- Curves --------------------------------------------------------

  void _mutateCurves(CurvesState newCurves) {
    _editState = _editState.copyWith(curves: newCurves);
    // Instant feedback for the curve graph itself (pure Dart, no async).
    notifyListeners();
    // The photo preview's LUT texture updates a beat later, once decoded.
    _regenerateCurveLut();
  }

  /// Adds a new point to [channel]'s curve, inserted in sorted x order.
  /// Returns the index it landed at, so the caller can keep dragging it.
  int addCurvePoint(CurveChannel channel, CurvePoint point) {
    final curve = _editState.curves.forChannel(channel);
    final points = List<CurvePoint>.from(curve.points);
    var insertIndex = points.indexWhere((p) => p.x > point.x);
    if (insertIndex == -1) insertIndex = points.length;
    points.insert(insertIndex, point);
    _mutateCurves(_editState.curves.withChannel(channel, ChannelCurve(points)));
    return insertIndex;
  }

  void updateCurvePoint(CurveChannel channel, int index, CurvePoint newPoint) {
    final curve = _editState.curves.forChannel(channel);
    if (index < 0 || index >= curve.points.length) return;
    final points = List<CurvePoint>.from(curve.points);

    final isEndpoint = index == 0 || index == points.length - 1;
    double x;
    if (isEndpoint) {
      x = index == 0 ? 0.0 : 1.0; // endpoints stay pinned horizontally
    } else {
      final minX = points[index - 1].x + 0.02;
      final maxX = points[index + 1].x - 0.02;
      x = newPoint.x.clamp(minX, maxX);
    }
    final y = newPoint.y.clamp(0.0, 1.0);

    points[index] = CurvePoint(x, y);
    _mutateCurves(_editState.curves.withChannel(channel, ChannelCurve(points)));
  }

  void removeCurvePoint(CurveChannel channel, int index) {
    final curve = _editState.curves.forChannel(channel);
    if (index <= 0 || index >= curve.points.length - 1) return; // keep endpoints
    _undoStack.add(_editState);
    _redoStack.clear();
    final points = List<CurvePoint>.from(curve.points)..removeAt(index);
    _mutateCurves(_editState.curves.withChannel(channel, ChannelCurve(points)));
  }

  void resetCurve(CurveChannel channel) {
    final curve = _editState.curves.forChannel(channel);
    if (curve.isIdentity) return;
    _undoStack.add(_editState);
    _redoStack.clear();
    _mutateCurves(_editState.curves.withChannel(channel, ChannelCurve.identity));
  }

  Future<void> _regenerateCurveLut() async {
    final myGeneration = ++_lutGeneration;
    final bytes = buildCurveLutBytes(_editState.curves);
    final image = await ShaderEngine.instance.decodePixels(bytes, 256, 1);
    if (myGeneration != _lutGeneration) {
      // A newer regeneration started (or finished) while this one was
      // decoding — discard this now-stale result rather than let it
      // overwrite a more recent one.
      image.dispose();
      return;
    }
    _curveLut?.dispose();
    _curveLut = image;
    notifyListeners();
  }

  // --- Color Grading -----------------------------------------------

  /// Updates one tonal range's hue/saturation (from dragging its color
  /// wheel) or luminance (from its slider). Pass only what changed —
  /// unset fields keep their current value.
  void updateColorGradeRange(GradeRange range, {double? hue, double? saturation, double? luminance}) {
    final current = _editState.colorGrade.forRange(range);
    final updated = current.copyWith(hue: hue, saturation: saturation, luminance: luminance);
    if (updated == current) return;
    _editState = _editState.copyWith(
      colorGrade: _editState.colorGrade.withRange(range, updated),
    );
    notifyListeners();
  }

  void updateColorGradeBlending(double value) {
    if (_editState.colorGrade.blending == value) return;
    _editState = _editState.copyWith(
      colorGrade: _editState.colorGrade.copyWith(blending: value),
    );
    notifyListeners();
  }

  void resetColorGradeRange(GradeRange range) {
    final current = _editState.colorGrade.forRange(range);
    if (current.isNeutral) return;
    _undoStack.add(_editState);
    _redoStack.clear();
    _editState = _editState.copyWith(
      colorGrade: _editState.colorGrade.withRange(range, const ColorGradeRange()),
    );
    notifyListeners();
  }

  // --- Blur ------------------------------------------------------------

  /// Moves the focus point (dragged directly on the photo). Doesn't push
  /// undo itself — callers should call beginAdjustmentGesture() once at
  /// the start of the drag, same as sliders and curve points. Also
  /// switches back to point mode, since dragging manually is a clear
  /// signal the user wants direct control over subject-mask mode.
  void updateBlurFocus(double x, double y) {
    _editState = _editState.copyWith(
      blur: _editState.blur.copyWith(
        focusX: x.clamp(0.0, 1.0),
        focusY: y.clamp(0.0, 1.0),
        useSubjectMask: false,
      ),
    );
    notifyListeners();
  }

  void updateBlurAmount(double value) {
    if (_editState.blur.amount == value) return;
    _editState = _editState.copyWith(blur: _editState.blur.copyWith(amount: value));
    notifyListeners();
  }

  void updateBlurSize(double value) {
    if (_editState.blur.size == value) return;
    _editState = _editState.copyWith(blur: _editState.blur.copyWith(size: value));
    notifyListeners();
  }

  void setBlurEnabled(bool value) {
    if (_editState.blur.enabled == value) return;
    _editState = _editState.copyWith(blur: _editState.blur.copyWith(enabled: value));
    notifyListeners();
  }

  void setBokehShape(BokehShape shape) {
    if (_editState.blur.bokehShape == shape) return;
    _editState = _editState.copyWith(blur: _editState.blur.copyWith(bokehShape: shape));
    notifyListeners();
  }

  void updateCatEye(double value) {
    if (_editState.blur.catEye == value) return;
    _editState = _editState.copyWith(blur: _editState.blur.copyWith(catEye: value));
    notifyListeners();
  }

  void updateBokehBoost(double value) {
    if (_editState.blur.bokehBoost == value) return;
    _editState = _editState.copyWith(blur: _editState.blur.copyWith(bokehBoost: value));
    notifyListeners();
  }

  void resetBlur() {
    if (_editState.blur.isNeutral) return;
    _undoStack.add(_editState);
    _redoStack.clear();
    _editState = _editState.copyWith(blur: const BlurState());
    notifyListeners();
  }

  /// Toggles subject mode on/off without touching the cached mask or
  /// re-running detection — used when the mask is already available.
  void setUseSubjectMask(bool value) {
    if (_editState.blur.useSubjectMask == value) return;
    _editState = _editState.copyWith(blur: _editState.blur.copyWith(useSubjectMask: value));
    notifyListeners();
  }

  /// Runs on-device subject segmentation (see SubjectSegmentationService)
  /// and switches Blur into subject mode once it succeeds. If a mask was
  /// already computed earlier this session (or reloaded from disk), this
  /// just re-activates it instantly instead of re-running detection.
  Future<void> detectSubject() async {
    if (_isDetectingSubject) return;
    final path = _imagePath;
    final dir = _projectDir;
    if (path == null || dir == null) return;

    if (_subjectMask != null) {
      _editState = _editState.copyWith(
        blur: _editState.blur.copyWith(useSubjectMask: true),
      );
      notifyListeners();
      return;
    }

    _isDetectingSubject = true;
    _subjectDetectionError = null;
    notifyListeners();
    try {
      final result = await SubjectSegmentationService.instance.detectSubjectMask(path);
      final image = await ShaderEngine.instance.decodePixels(
        result.rgbaBytes,
        result.width,
        result.height,
      );
      _subjectMask?.dispose();
      _subjectMask = image;
      _editState = _editState.copyWith(
        blur: _editState.blur.copyWith(useSubjectMask: true),
      );

      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        final maskFile = File(p.join(dir, 'subject_mask.png'));
        await maskFile.writeAsBytes(byteData.buffer.asUint8List());
      }
    } catch (e) {
      _subjectDetectionError = 'Subject detection failed: $e';
    } finally {
      _isDetectingSubject = false;
      notifyListeners();
    }
  }

  // --- Effects -----------------------------------------------------

  void setEffect(EffectType type, double value) {
    if (type.valueOf(_editState.effects) == value) return;
    _editState = _editState.copyWith(effects: type.apply(_editState.effects, value));
    notifyListeners();
  }

  void resetEffects() {
    if (_editState.effects.isNeutral) return;
    _undoStack.add(_editState);
    _redoStack.clear();
    _editState = _editState.copyWith(effects: const EffectsState());
    notifyListeners();
  }

  // --- Crop ----------------------------------------------------------

  /// Directly sets the crop rect (used while dragging a handle). Pass
  /// only what changed; each bound is clamped to stay valid (left<right,
  /// top<bottom, everything within 0..1). Doesn't push undo itself —
  /// callers should call beginAdjustmentGesture() once at drag start.
  void updateCropRect({double? left, double? top, double? right, double? bottom}) {
    final crop = _editState.crop;
    var l = (left ?? crop.left).clamp(0.0, 1.0);
    var t = (top ?? crop.top).clamp(0.0, 1.0);
    var r = (right ?? crop.right).clamp(0.0, 1.0);
    var b = (bottom ?? crop.bottom).clamp(0.0, 1.0);
    const minSize = 0.08;
    if (r - l < minSize) {
      if (left != null) {
        l = r - minSize;
      } else {
        r = l + minSize;
      }
    }
    if (b - t < minSize) {
      if (top != null) {
        t = b - minSize;
      } else {
        b = t + minSize;
      }
    }
    _editState = _editState.copyWith(
      crop: crop.copyWith(left: l, top: t, right: r, bottom: b),
    );
    notifyListeners();
  }

  /// Snaps the crop rect to [ratio] (width/height), centered within the
  /// current post-rotation frame. Pass null for "Free" — just changes
  /// the remembered label without touching the current rect.
  void setCropAspectPreset(double? ratio, String? label) {
    final img = _image;
    if (img == null) return;
    if (ratio == null) {
      _editState = _editState.copyWith(
        crop: _editState.crop.copyWith(aspectPresetLabel: label, clearAspectPresetLabel: label == null),
      );
      notifyListeners();
      return;
    }
    final swapped = _editState.crop.rotationSteps == 1 || _editState.crop.rotationSteps == 3;
    final frameRatio = swapped ? img.height / img.width : img.width / img.height;
    final relative = ratio / frameRatio;
    double cw, ch;
    if (relative >= 1) {
      cw = 1.0;
      ch = 1.0 / relative;
    } else {
      ch = 1.0;
      cw = relative;
    }
    final left = (1 - cw) / 2;
    final top = (1 - ch) / 2;
    _editState = _editState.copyWith(
      crop: _editState.crop.copyWith(
        left: left,
        top: top,
        right: left + cw,
        bottom: top + ch,
        aspectPresetLabel: label,
      ),
    );
    notifyListeners();
  }

  /// "Original" preset — full frame, but locks future handle drags to the
  /// frame's own shape (as opposed to "Free", which resets nothing and
  /// removes any lock).
  void setCropOriginalPreset() {
    _editState = _editState.copyWith(
      crop: _editState.crop.copyWith(
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
        aspectPresetLabel: 'Original',
      ),
    );
    notifyListeners();
  }

  void updateStraighten(double degrees) {
    if (_editState.crop.straightenAngle == degrees) return;
    _editState = _editState.copyWith(crop: _editState.crop.copyWith(straightenAngle: degrees));
    notifyListeners();
  }

  /// Rotates 90 degrees clockwise. Resets the crop rect to full-frame,
  /// since the frame the rect was defined within just changed shape.
  void rotateCrop90() {
    _undoStack.add(_editState);
    _redoStack.clear();
    final nextSteps = (_editState.crop.rotationSteps + 1) % 4;
    _editState = _editState.copyWith(
      crop: _editState.crop.copyWith(
        rotationSteps: nextSteps,
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
        clearAspectPresetLabel: true,
      ),
    );
    notifyListeners();
  }

  void toggleFlipHorizontal() {
    _undoStack.add(_editState);
    _redoStack.clear();
    _editState = _editState.copyWith(
      crop: _editState.crop.copyWith(flipHorizontal: !_editState.crop.flipHorizontal),
    );
    notifyListeners();
  }

  void toggleFlipVertical() {
    _undoStack.add(_editState);
    _redoStack.clear();
    _editState = _editState.copyWith(
      crop: _editState.crop.copyWith(flipVertical: !_editState.crop.flipVertical),
    );
    notifyListeners();
  }

  void resetCrop() {
    if (_editState.crop.isNeutral) return;
    _undoStack.add(_editState);
    _redoStack.clear();
    _editState = _editState.copyWith(crop: const CropState());
    notifyListeners();
  }

  // --- Heal ------------------------------------------------------------

  /// Adds one painted point (normalized 0..1) to the pending stroke —
  /// not yet baked into the persisted mask until applyHeal() runs.
  ///
  /// Skips points too close to the last one kept: pointer-move events fire
  /// far more often than the brush dabs need, and the preview painter
  /// redraws every accumulated point on every frame — an unthinned stroke
  /// gets visibly laggier to paint the longer it runs.
  void addHealStrokePoint(Offset normalized) {
    if (_tooCloseToLast(_healStrokePoints, normalized)) return;
    _healStrokePoints.add(normalized);
    notifyListeners();
  }

  void clearPendingHealStroke() {
    if (_healStrokePoints.isEmpty) return;
    _healStrokePoints.clear();
    notifyListeners();
  }

  void updateHealBrushSize(double value) {
    if (_editState.heal.brushSize == value) return;
    _editState = _editState.copyWith(heal: _editState.heal.copyWith(brushSize: value));
    notifyListeners();
  }

  /// Bakes the pending painted stroke into the persisted heal mask
  /// (unioned with anything healed earlier) and re-runs diffusion inpaint
  /// over the whole thing. Real processing — expect this to take a
  /// second or two, longer for bigger brushed areas.
  Future<void> applyHeal() async {
    final img = _image;
    final dir = _projectDir;
    if (img == null || dir == null || _healStrokePoints.isEmpty || _isApplyingHeal) return;

    _isApplyingHeal = true;
    _healError = null;
    notifyListeners();
    try {
      const workingSize = 900;
      final longSide = math.max(img.width, img.height);
      final scale = longSide > workingSize ? workingSize / longSide : 1.0;
      final w = (img.width * scale).round().clamp(1, img.width);
      final h = (img.height * scale).round().clamp(1, img.height);

      // Points were captured relative to whatever's currently on screen,
      // which reflects any active crop/straighten/rotate/flip — but the
      // mask texture is sampled in raw-image space, so convert before
      // rendering (otherwise the mark lands in the wrong place whenever
      // a crop is active while healing).
      final imageAspect = img.width / img.height;
      final rawPoints = _healStrokePoints
          .map((pt) => mapOutputToRaw(pt, _editState.crop, imageAspect))
          .toList();

      final newMask = await HealEngine.instance.renderMask(
        normalizedPoints: rawPoints,
        brushSizeFraction: _editState.heal.brushSize / 100,
        width: w,
        height: h,
        existingMask: _healMask,
      );

      // Two engines behind one brush. The on-device diffusion fill is
      // instant but only convincing on small marks against simple
      // backgrounds; LaMa reconstructs actual structure, at the cost of a
      // round trip. If the server drops mid-request we fall back rather
      // than losing the user's stroke.
      ui.Image healed;
      if (useAiRemove) {
        try {
          healed = await _aiInpaint(source: img, mask: newMask);
        } on AiException catch (e) {
          _healError = '${e.message} Used on-device heal instead.';
          healed = await HealEngine.instance.diffuseInpaint(
            source: img,
            mask: newMask,
            workingSize: workingSize,
          );
        }
      } else {
        healed = await HealEngine.instance.diffuseInpaint(
          source: img,
          mask: newMask,
          workingSize: workingSize,
        );
      }

      _healMask?.dispose();
      _healMask = newMask;
      _healedTexture?.dispose();
      _healedTexture = healed;
      _healStrokePoints.clear();
      _editState = _editState.copyWith(heal: _editState.heal.copyWith(isActive: true));

      final maskBytes = await newMask.toByteData(format: ui.ImageByteFormat.png);
      if (maskBytes != null) {
        await File(p.join(dir, 'heal_mask.png')).writeAsBytes(maskBytes.buffer.asUint8List());
      }
      final healedBytes = await healed.toByteData(format: ui.ImageByteFormat.png);
      if (healedBytes != null) {
        await File(p.join(dir, 'heal_result.png')).writeAsBytes(healedBytes.buffer.asUint8List());
      }
    } catch (e) {
      _healError = 'Heal failed: $e';
    } finally {
      _isApplyingHeal = false;
      notifyListeners();
    }
  }

  void resetHeal() {
    if (_editState.heal.isNeutral && _healStrokePoints.isEmpty) return;
    _undoStack.add(_editState);
    _redoStack.clear();
    _healStrokePoints.clear();
    _healMask?.dispose();
    _healMask = null;
    _healedTexture?.dispose();
    _healedTexture = null;
    _editState = _editState.copyWith(heal: const HealState());
    notifyListeners();
  }

  // --- Masking ---------------------------------------------------------

  /// Selecting null just deselects (closes whichever mask's editor is
  /// open) without deleting anything. Switching masks clears any
  /// not-yet-applied brush stroke, since it belonged to whichever mask
  /// was selected before.
  void selectMask(String? id) {
    _selectedMaskId = id;
    _maskStrokePoints.clear();
    notifyListeners();
  }

  /// Adds a new mask of [type] (if under the 3-slot limit) and selects
  /// it. Returns the new mask's id, or null if already full.
  String? addMask(MaskShapeType type) {
    if (_editState.masking.isFull) return null;
    _undoStack.add(_editState);
    _redoStack.clear();
    final id = _uuid.v4();
    final slot = MaskSlot(id: id, type: type);
    final newSlots = [..._editState.masking.slots, slot];
    _editState = _editState.copyWith(masking: _editState.masking.copyWith(slots: newSlots));
    _selectedMaskId = id;
    _maskStrokePoints.clear();
    notifyListeners();
    return id;
  }

  void deleteMask(String id) {
    _undoStack.add(_editState);
    _redoStack.clear();
    final newSlots = _editState.masking.slots.where((s) => s.id != id).toList();
    _editState = _editState.copyWith(masking: _editState.masking.copyWith(slots: newSlots));
    if (_selectedMaskId == id) {
      _selectedMaskId = null;
      _maskStrokePoints.clear();
    }
    _maskBrushImages.remove(id)?.dispose();
    notifyListeners();
    _deleteProjectFile('mask_brush_$id.png');
  }

  /// Hides/shows one mask without deleting it. Not routed through
  /// [_updateSelectedMask] because the visibility toggle lives in the
  /// list, where nothing is selected.
  void setMaskEnabled(String id, bool enabled) {
    final slots = _editState.masking.slots
        .map((s) => s.id == id ? s.copyWith(enabled: enabled) : s)
        .toList();
    _editState =
        _editState.copyWith(masking: _editState.masking.copyWith(slots: slots));
    notifyListeners();
  }

  void _updateSelectedMask(MaskSlot Function(MaskSlot) update) {
    final id = _selectedMaskId;
    if (id == null) return;
    final slots = _editState.masking.slots.map((s) => s.id == id ? update(s) : s).toList();
    _editState = _editState.copyWith(masking: _editState.masking.copyWith(slots: slots));
    notifyListeners();
  }

  void updateMaskLinear({double? startX, double? startY, double? endX, double? endY}) {
    _updateSelectedMask((s) => s.copyWith(
          linearStartX: startX,
          linearStartY: startY,
          linearEndX: endX,
          linearEndY: endY,
        ));
  }

  void updateMaskRadial({
    double? centerX,
    double? centerY,
    double? radiusX,
    double? radiusY,
    double? feather,
  }) {
    _updateSelectedMask((s) => s.copyWith(
          radialCenterX: centerX,
          radialCenterY: centerY,
          radialRadiusX: radiusX,
          radialRadiusY: radiusY,
          radialFeather: feather,
        ));
  }

  void updateMaskLuminanceRange({
    double? low,
    double? high,
    double? smoothness,
  }) {
    _updateSelectedMask(
      (s) => s.copyWith(
        lumLow: low,
        lumHigh: high,
        lumSmoothness: smoothness,
      ),
    );
  }

  void updateMaskColorTolerance(double tolerance) {
    _updateSelectedMask((s) => s.copyWith(colorTolerance: tolerance));
  }

  /// Samples the rendered photo at [normalized] and makes that the
  /// selected Color Range mask's target.
  ///
  /// Reads from a cached low-resolution render of the *current edit*, not
  /// the raw file: the user is pointing at what they can see, and after a
  /// warmth shift or a curve the raw pixel underneath is a different
  /// colour from the one on screen.
  Future<void> sampleMaskColorAt(Offset normalized) async {
    final slot = selectedMask;
    if (slot == null || slot.type != MaskShapeType.colorRange) return;

    final sample = await _sampleRenderedPixel(normalized);
    if (sample == null) return;

    _updateSelectedMask(
      (s) => s.copyWith(
        colorR: sample.$1,
        colorG: sample.$2,
        colorB: sample.$3,
        colorSampled: true,
      ),
    );
  }

  /// Cached preview used for colour sampling, plus the state it was
  /// rendered for. A drag emits sample requests every frame; re-rendering
  /// the photo for each one would make the eyedropper unusable.
  Uint8List? _samplePixels;
  int _sampleWidth = 0;
  int _sampleHeight = 0;
  int? _sampleSignature;

  Future<(double, double, double)?> _sampleRenderedPixel(
    Offset normalized,
  ) async {
    final image = _image;
    if (image == null) return null;

    final signature = _pixelSignature();
    if (_samplePixels == null || signature != _sampleSignature) {
      try {
        // 512px long edge: fine enough that a fingertip lands on the
        // intended feature, coarse enough to re-render quickly when the
        // edit changes underneath.
        const previewSize = 512;
        final longSide = math.max(image.width, image.height);
        final scale = longSide > previewSize ? previewSize / longSide : 1.0;
        _sampleWidth = (image.width * scale).round().clamp(1, previewSize);
        _sampleHeight = (image.height * scale).round().clamp(1, previewSize);
        _samplePixels = await _renderRgbaAtMaxDimension(previewSize);
        _sampleSignature = signature;
      } catch (_) {
        return null;
      }
    }

    final pixels = _samplePixels;
    if (pixels == null) return null;

    // The overlay reports a position in the *displayed* frame, which is
    // post-crop; the render it is sampling is the same framing, so the
    // coordinates line up directly.
    final x = (normalized.dx * (_sampleWidth - 1)).round().clamp(
          0,
          _sampleWidth - 1,
        );
    final y = (normalized.dy * (_sampleHeight - 1)).round().clamp(
          0,
          _sampleHeight - 1,
        );
    final offset = (y * _sampleWidth + x) * 4;
    if (offset + 2 >= pixels.length) return null;

    return (
      pixels[offset] / 255.0,
      pixels[offset + 1] / 255.0,
      pixels[offset + 2] / 255.0,
    );
  }

  void toggleSelectedMaskInvert() {
    _updateSelectedMask((s) => s.copyWith(invert: !s.invert));
  }

  void setMaskAdjustment({double? exposure, double? contrast, double? saturation, double? warmth}) {
    _updateSelectedMask((s) => s.copyWith(
          exposure: exposure,
          contrast: contrast,
          saturation: saturation,
          warmth: warmth,
        ));
  }

  /// Adds one painted point (normalized 0..1, in the CURRENT on-screen
  /// frame) to the pending stroke for whichever mask is selected — not
  /// yet baked in until applyMaskBrush() runs.
  ///
  /// Same distance-thinning as [addHealStrokePoint], for the same reason.
  void addMaskStrokePoint(Offset normalized) {
    if (_tooCloseToLast(_maskStrokePoints, normalized)) return;
    _maskStrokePoints.add(normalized);
    notifyListeners();
  }

  /// Normalized-space spacing below which a new stroke point is dropped
  /// rather than kept — about 5px on a 1000px-wide preview. Small enough
  /// to be invisible in the stroke shape, large enough to keep a long
  /// paint gesture's point count (and so its per-frame redraw cost) from
  /// growing unbounded.
  static const _minStrokePointSpacing = 0.005;

  bool _tooCloseToLast(List<Offset> points, Offset next) {
    if (points.isEmpty) return false;
    return (next - points.last).distance < _minStrokePointSpacing;
  }

  void clearPendingMaskStroke() {
    if (_maskStrokePoints.isEmpty) return;
    _maskStrokePoints.clear();
    notifyListeners();
  }

  /// Bakes the pending painted stroke into the selected mask's persisted
  /// brush texture (unioned with anything painted for it earlier).
  Future<void> applyMaskBrush() async {
    final img = _image;
    final dir = _projectDir;
    final id = _selectedMaskId;
    final slot = selectedMask;
    if (img == null ||
        dir == null ||
        id == null ||
        slot == null ||
        slot.type != MaskShapeType.brush ||
        _maskStrokePoints.isEmpty ||
        _isApplyingMaskBrush) {
      return;
    }

    _isApplyingMaskBrush = true;
    notifyListeners();
    try {
      const workingSize = 900;
      final longSide = math.max(img.width, img.height);
      final scale = longSide > workingSize ? workingSize / longSide : 1.0;
      final w = (img.width * scale).round().clamp(1, img.width);
      final h = (img.height * scale).round().clamp(1, img.height);

      final imageAspect = img.width / img.height;
      final rawPoints =
          _maskStrokePoints.map((pt) => mapOutputToRaw(pt, _editState.crop, imageAspect)).toList();

      // Reuses HealEngine's mask renderer — it's a generic "paint circles
      // onto a mask" utility, not Heal-specific despite the class name.
      final newMask = await HealEngine.instance.renderMask(
        normalizedPoints: rawPoints,
        brushSizeFraction: 0.12,
        width: w,
        height: h,
        existingMask: _maskBrushImages[id],
      );
      _maskBrushImages[id]?.dispose();
      _maskBrushImages[id] = newMask;
      _maskStrokePoints.clear();

      final bytes = await newMask.toByteData(format: ui.ImageByteFormat.png);
      if (bytes != null) {
        await File(p.join(dir, 'mask_brush_$id.png')).writeAsBytes(bytes.buffer.asUint8List());
      }
    } finally {
      _isApplyingMaskBrush = false;
      notifyListeners();
    }
  }

  void resetMasking() {
    if (_editState.masking.isNeutral) return;
    _undoStack.add(_editState);
    _redoStack.clear();
    for (final img in _maskBrushImages.values) {
      img.dispose();
    }
    _maskBrushImages.clear();
    _selectedMaskId = null;
    _maskStrokePoints.clear();
    _editState = _editState.copyWith(masking: const MaskingState());
    notifyListeners();
  }

  Future<void> _deleteProjectFile(String filename) async {
    final dir = _projectDir;
    if (dir == null) return;
    try {
      final file = File(p.join(dir, filename));
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Non-fatal.
    }
  }

  // --- Histogram ---------------------------------------------------------

  /// Every state change schedules a histogram refresh.
  ///
  /// Overriding [notifyListeners] rather than calling a scheduler from
  /// each of the ~40 mutators is what keeps the histogram from silently
  /// going stale the next time someone adds a control and forgets.
  @override
  void notifyListeners() {
    super.notifyListeners();
    _scheduleHistogram();
  }

  void _scheduleHistogram() {
    if (_isLoading || _image == null || _isBuildingHistogram) return;

    // Recomputing after our own notify would loop forever, so the work is
    // keyed on a signature of everything that can change the pixels.
    final signature = _pixelSignature();
    if (signature == _histogramSignature) return;

    _histogramTimer?.cancel();
    _histogramTimer = Timer(const Duration(milliseconds: 220), () {
      _buildHistogram(signature);
    });
  }

  /// Hash of every input that affects the rendered result: the shader
  /// uniforms, the curve LUT (a texture, so absent from the uniforms),
  /// and the identity of each optional mask texture.
  int _pixelSignature() {
    return Object.hash(
      Object.hashAll(_editState.toUniformList()),
      jsonEncode(_editState.curves.toJson()),
      identityHashCode(_healedTexture),
      identityHashCode(_subjectMask),
      Object.hashAll(maskBrushesForShader.map(identityHashCode)),
    );
  }

  Future<void> _buildHistogram(int signature) async {
    if (_image == null || _isBuildingHistogram) return;
    _isBuildingHistogram = true;
    try {
      // 192px longest edge: ~37k samples, which is far more than the 256
      // buckets need to be statistically stable, and cheap enough to run
      // on the UI isolate without a dropped frame.
      final bytes = await _renderRgbaAtMaxDimension(192);
      _histogram = HistogramData.fromRgba(bytes);
      _histogramSignature = signature;
    } catch (_) {
      // A histogram is a readout, not a feature — if a render fails
      // mid-edit the last good one stays on screen.
    } finally {
      _isBuildingHistogram = false;
      // Deliberately super: this notify must not re-enter the scheduler.
      super.notifyListeners();
    }
  }

  /// Renders the current edit to raw RGBA at a bounded size.
  Future<Uint8List> _renderRgbaAtMaxDimension(int maxDimension) async {
    final rendered = await _renderToImage(maxDimension);
    try {
      final data = await rendered.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) throw StateError('could not read rendered pixels');
      return data.buffer.asUint8List();
    } finally {
      rendered.dispose();
    }
  }

  // --- AI selection & removal ------------------------------------------

  /// Re-probes the backend. Cheap and safe to call from a Retry button.
  Future<void> refreshAiAvailability({bool force = true}) async {
    final available = await AiService.instance.checkAvailability(force: force);
    if (available == _aiAvailable) return;
    _aiAvailable = available;
    notifyListeners();
  }

  void setUseAiRemove(bool value) {
    if (_useAiRemove == value) return;
    _useAiRemove = value;
    notifyListeners();
  }

  void clearAiMaskError() {
    if (_aiMaskError == null) return;
    _aiMaskError = null;
    notifyListeners();
  }

  /// Adds an AI mask slot and immediately runs segmentation for it.
  ///
  /// The slot is created *before* the request so the user sees a row with
  /// a spinner rather than a frozen panel, and so the mask survives if
  /// they navigate away and back while it is still running.
  Future<void> addAiMask(AiMaskMode mode, {String? prompt}) async {
    if (_editState.masking.isFull) return;
    _undoStack.add(_editState);
    _redoStack.clear();
    final id = _uuid.v4();
    final slot = MaskSlot(
      id: id,
      type: MaskShapeType.ai,
      aiMode: mode,
      aiPrompt: prompt?.trim() ?? '',
      aiPending: true,
      // Background is literally "everything the subject mask is not", so
      // it is the subject pipeline with the invert flag already set - no
      // separate model, no second round trip.
      invert: mode == AiMaskMode.background,
    );
    _editState = _editState.copyWith(
      masking: _editState.masking
          .copyWith(slots: [..._editState.masking.slots, slot]),
    );
    _aiMaskError = null;
    notifyListeners();
    await _runAiSegmentation(id);
  }

  /// Re-runs segmentation for an existing AI mask, e.g. after the user
  /// decided the first attempt caught the wrong object.
  Future<void> regenerateAiMask(String id) async {
    final slot = _slotById(id);
    if (slot == null || slot.type != MaskShapeType.ai || slot.aiPending) return;
    _setSlotPending(id, true);
    await _runAiSegmentation(id);
  }

  Future<void> _runAiSegmentation(String id) async {
    final img = _image;
    final dir = _projectDir;
    final slot = _slotById(id);
    if (img == null || dir == null || slot == null || slot.aiMode == null) {
      _setSlotPending(id, false);
      return;
    }

    try {
      // Masks live in raw-image space so they stay locked to content
      // through later crop/rotate/flip edits, exactly like brush
      // textures - so the raw image is what gets uploaded, not the
      // currently-framed preview.
      final png = await _encodeImagePng(img, AiConfig.uploadMaxDimension);
      final result = await AiService.instance.segment(
        imagePng: png,
        mode: slot.aiMode!,
        prompt: slot.aiPrompt,
      );

      final mask = await ShaderEngine.instance.decodePixels(
        result.rgbaBytes,
        result.width,
        result.height,
      );
      _maskBrushImages[id]?.dispose();
      _maskBrushImages[id] = mask;

      final bytes = await mask.toByteData(format: ui.ImageByteFormat.png);
      if (bytes != null) {
        await File(p.join(dir, 'mask_brush_$id.png'))
            .writeAsBytes(bytes.buffer.asUint8List());
      }
      _aiMaskError = null;
    } on AiException catch (e) {
      _aiMaskError = e.message;
    } catch (e) {
      _aiMaskError = 'Selection failed: $e';
    } finally {
      _setSlotPending(id, false);
    }
  }

  /// Sends the image and heal mask to LaMa and decodes the result.
  Future<ui.Image> _aiInpaint({
    required ui.Image source,
    required ui.Image mask,
  }) async {
    final imagePng = await _encodeImagePng(source, AiConfig.uploadMaxDimension);
    final maskBytes = await mask.toByteData(format: ui.ImageByteFormat.png);
    if (maskBytes == null) {
      throw const AiException('Could not encode the heal mask.');
    }
    final resultPng = await AiService.instance.remove(
      imagePng: imagePng,
      maskPng: maskBytes.buffer.asUint8List(),
    );
    final codec = await ui.instantiateImageCodec(resultPng);
    return (await codec.getNextFrame()).image;
  }

  MaskSlot? _slotById(String id) {
    for (final slot in _editState.masking.slots) {
      if (slot.id == id) return slot;
    }
    return null;
  }

  void _setSlotPending(String id, bool pending) {
    final slots = _editState.masking.slots
        .map((s) => s.id == id ? s.copyWith(aiPending: pending) : s)
        .toList();
    _editState =
        _editState.copyWith(masking: _editState.masking.copyWith(slots: slots));
    notifyListeners();
  }

  /// Re-encodes [image] as PNG, scaled so its longest edge is at most
  /// [maxDimension]. Uploading a 48MP original would spend seconds on
  /// transfer for a mask that gets resampled anyway.
  Future<Uint8List> _encodeImagePng(ui.Image image, int maxDimension) async {
    final longSide = math.max(image.width, image.height);
    if (longSide <= maxDimension) {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const AiException('Could not encode the image.');
      return data.buffer.asUint8List();
    }

    final scale = maxDimension / longSide;
    final w = (image.width * scale).round().clamp(1, maxDimension);
    final h = (image.height * scale).round().clamp(1, maxDimension);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final scaled = await recorder.endRecording().toImage(w, h);
    try {
      final data = await scaled.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const AiException('Could not encode the image.');
      return data.buffer.asUint8List();
    } finally {
      scaled.dispose();
    }
  }

  // --- Undo / redo -----------------------------------------------------

  void undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_editState);
    _editState = _undoStack.removeLast();
    _regenerateCurveLut();
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_editState);
    _editState = _redoStack.removeLast();
    _regenerateCurveLut();
    notifyListeners();
  }

  // --- Rendering ---------------------------------------------------

  /// Renders the current edit at the image's full native resolution and
  /// returns PNG bytes — used for export.
  Future<Uint8List> renderFullResolutionPng() {
    final img = _image;
    if (img == null) throw StateError('No image loaded');
    return _renderPngAtMaxDimension(math.max(img.width, img.height));
  }

  Future<Uint8List> _renderPngAtMaxDimension(int maxDimension) async {
    final rendered = await _renderToImage(maxDimension);
    try {
      final byteData = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw StateError('could not encode render');
      return byteData.buffer.asUint8List();
    } finally {
      rendered.dispose();
    }
  }

  /// Renders the current edit through the shader at a bounded size.
  /// Shared by export, the saved preview and the histogram, so all three
  /// are guaranteed to show the same pixels.
  Future<ui.Image> _renderToImage(int maxDimension) async {
    final img = _image;
    final lut = _curveLut;
    final mask = subjectMaskForShader;
    final healMask = healMaskForShader;
    final healedTexture = healedTextureForShader;
    if (img == null || lut == null || mask == null || healMask == null || healedTexture == null) {
      throw StateError('No image loaded');
    }
    final crop = _editState.crop;
    final swapped = crop.rotationSteps == 1 || crop.rotationSteps == 3;
    final postW = swapped ? img.height : img.width;
    final postH = swapped ? img.width : img.height;
    final outputW = postW * crop.cropWidth;
    final outputH = postH * crop.cropHeight;

    final longSide = math.max(outputW, outputH);
    final scale = longSide > maxDimension ? maxDimension / longSide : 1.0;
    final w = (outputW * scale).round().clamp(1, 1 << 20);
    final h = (outputH * scale).round().clamp(1, 1 << 20);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = Size(w.toDouble(), h.toDouble());
    final shader = ShaderEngine.instance.buildShader(
      image: img,
      curveLut: lut,
      subjectMask: mask,
      healMask: healMask,
      healedTexture: healedTexture,
      maskBrushes: maskBrushesForShader,
      width: size.width,
      height: size.height,
      state: _editState,
    );
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(w, h);
    } finally {
      picture.dispose();
    }
  }

  @override
  void dispose() {
    _histogramTimer?.cancel();
    _image?.dispose();
    _curveLut?.dispose();
    _subjectMask?.dispose();
    _healMask?.dispose();
    _healedTexture?.dispose();
    for (final img in _maskBrushImages.values) {
      img.dispose();
    }
    super.dispose();
  }
}
