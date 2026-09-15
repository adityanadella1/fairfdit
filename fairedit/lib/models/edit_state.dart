import 'package:flutter/foundation.dart';

import 'blur_state.dart';
import 'color_grade_state.dart';
import 'crop_state.dart';
import 'curves_state.dart';
import 'effects_state.dart';
import 'heal_state.dart';
import 'mask_state.dart';

/// Holds every non-destructive edit parameter for a photo.
///
/// This will grow as more features are built (Crop, Effects, Masks).
/// Adjustments values are kept in the -100..100 range the
/// UI shows, and normalized in [toUniformList] to what the shader expects.
@immutable
class EditState {
  final double exposure;
  final double contrast;
  final double highlights;
  final double shadows;
  final double whites;
  final double blacks;
  final double brightness;
  final double saturation;
  final double vibrance;
  final double warmth;
  final double tint;
  final CurvesState curves;
  final ColorGradeState colorGrade;
  final BlurState blur;
  final EffectsState effects;
  final CropState crop;
  final HealState heal;
  final MaskingState masking;

  const EditState({
    this.exposure = 0,
    this.contrast = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.whites = 0,
    this.blacks = 0,
    this.brightness = 0,
    this.saturation = 0,
    this.vibrance = 0,
    this.warmth = 0,
    this.tint = 0,
    this.curves = const CurvesState(),
    this.colorGrade = const ColorGradeState(),
    this.blur = const BlurState(),
    this.effects = const EffectsState(),
    this.crop = const CropState(),
    this.heal = const HealState(),
    this.masking = const MaskingState(),
  });

  /// True if none of the 11 basic-adjustment sliders have been touched.
  /// Deliberately independent of [curves] — the Adjust panel's Reset
  /// button only resets these, and shouldn't look "already at rest" just
  /// because curves happen to be untouched too, or vice versa.
  bool get isAdjustmentsNeutral =>
      exposure == 0 &&
      contrast == 0 &&
      highlights == 0 &&
      shadows == 0 &&
      whites == 0 &&
      blacks == 0 &&
      brightness == 0 &&
      saturation == 0 &&
      vibrance == 0 &&
      warmth == 0 &&
      tint == 0;

  /// True if nothing at all has been edited yet — used for the editor's
  /// general "Edited · hold to compare" indicator.
  bool get hasAnyEdits =>
      !isAdjustmentsNeutral ||
      !curves.isNeutral ||
      !colorGrade.isNeutral ||
      !blur.isNeutral ||
      !effects.isNeutral ||
      !crop.isNeutral ||
      !heal.isNeutral ||
      !masking.isNeutral;

  EditState copyWith({
    double? exposure,
    double? contrast,
    double? highlights,
    double? shadows,
    double? whites,
    double? blacks,
    double? brightness,
    double? saturation,
    double? vibrance,
    double? warmth,
    double? tint,
    CurvesState? curves,
    ColorGradeState? colorGrade,
    BlurState? blur,
    EffectsState? effects,
    CropState? crop,
    HealState? heal,
    MaskingState? masking,
  }) {
    return EditState(
      exposure: exposure ?? this.exposure,
      contrast: contrast ?? this.contrast,
      highlights: highlights ?? this.highlights,
      shadows: shadows ?? this.shadows,
      whites: whites ?? this.whites,
      blacks: blacks ?? this.blacks,
      brightness: brightness ?? this.brightness,
      saturation: saturation ?? this.saturation,
      vibrance: vibrance ?? this.vibrance,
      warmth: warmth ?? this.warmth,
      tint: tint ?? this.tint,
      curves: curves ?? this.curves,
      colorGrade: colorGrade ?? this.colorGrade,
      blur: blur ?? this.blur,
      effects: effects ?? this.effects,
      crop: crop ?? this.crop,
      heal: heal ?? this.heal,
      masking: masking ?? this.masking,
    );
  }

  /// Values fed to the shader, in the exact order declared in
  /// `shaders/edit_shader.frag` (right after `uSize`). Roughly -1.0..1.0
  /// for the basic adjustments; color grading values are normalized to
  /// their own natural ranges (see the comments below). Curves are NOT
  /// included here — they're sent as a separate LUT texture (see
  /// ShaderEngine / EditProvider), not as float uniforms.
  List<double> toUniformList() {
    return [
      exposure / 100,
      contrast / 100,
      highlights / 100,
      shadows / 100,
      whites / 100,
      blacks / 100,
      brightness / 100,
      saturation / 100,
      vibrance / 100,
      warmth / 100,
      tint / 100,
      // Color grading — hue in turns (0..1), saturation/luminance/blending
      // in 0..1 (or -1..1 for luminance), matching uGrade* uniforms below.
      colorGrade.shadows.hue / 360,
      colorGrade.shadows.saturation / 100,
      colorGrade.shadows.luminance / 100,
      colorGrade.midtones.hue / 360,
      colorGrade.midtones.saturation / 100,
      colorGrade.midtones.luminance / 100,
      colorGrade.highlights.hue / 360,
      colorGrade.highlights.saturation / 100,
      colorGrade.highlights.luminance / 100,
      colorGrade.blending / 100,
      // Blur — focus point is already 0..1, amount/size normalized to 0..1.
      // enabled folds straight into amount here: unchecking Apply should
      // hide the effect without erasing the stored amount/size/etc.
      blur.focusX,
      blur.focusY,
      blur.enabled ? blur.amount / 100 : 0,
      blur.size / 100,
      blur.bokehShape.index.toDouble(),
      blur.catEye / 100,
      blur.bokehBoost / 100,
      blur.useSubjectMask ? 1.0 : 0.0,
      // Effects — sharpen/clarity/dehaze are early-pipeline (raw-domain,
      // some use neighbor sampling); vignette/grain apply at the very end.
      effects.sharpen / 100,
      effects.clarity / 100,
      effects.dehaze / 100,
      effects.vignetteAmount / 100,
      effects.vignetteSize / 100,
      effects.grainAmount / 100,
      effects.grainSize / 100,
      // Crop/straighten/rotate/flip — left/top/right/bottom already 0..1;
      // straighten angle converted to radians here so the shader doesn't
      // need to; rotationSteps/flip as plain 0/1 flags.
      crop.left,
      crop.top,
      crop.right,
      crop.bottom,
      crop.straightenAngle * (3.14159265 / 180.0),
      crop.rotationSteps.toDouble(),
      crop.flipHorizontal ? 1.0 : 0.0,
      crop.flipVertical ? 1.0 : 0.0,
      // Masking — a fixed 3-slot layout (11 floats each), regardless of
      // how many masks actually exist. Empty slots get type=0 ("off"),
      // which the shader treats as a no-op the same way an all-zero
      // heal/subject mask is.
      for (var i = 0; i < MaskingState.maxSlots; i++) ...maskSlotUniforms(i),
    ];
  }

  /// The 11 floats for masking slot [index]: type, invert, 5 shape
  /// params (meaning depends on type — see edit_shader.frag), then
  /// exposure/contrast/saturation/warmth. Slots beyond how many masks
  /// exist yield an "off" (type=0) slot.
  List<double> maskSlotUniforms(int index) {
    if (index >= masking.slots.length) {
      return List<double>.filled(11, 0);
    }
    final slot = masking.slots[index];
    // A disabled mask is sent as an "off" slot rather than as a
    // zero-coverage one, so the shader skips its whole branch instead of
    // sampling a texture it is going to multiply by zero anyway.
    if (!slot.enabled) return List<double>.filled(11, 0);
    final typeValue = switch (slot.type) {
      MaskShapeType.linear => 1.0,
      MaskShapeType.radial => 2.0,
      // AI masks ride the same texture path as Brush — by the time the
      // shader runs, a mask is just coverage, whatever produced it.
      MaskShapeType.brush || MaskShapeType.ai => 3.0,
      MaskShapeType.luminanceRange => 4.0,
      MaskShapeType.colorRange => 5.0,
    };
    final List<double> shapeParams;
    switch (slot.type) {
      case MaskShapeType.linear:
        shapeParams = [slot.linearStartX, slot.linearStartY, slot.linearEndX, slot.linearEndY, 0];
        break;
      case MaskShapeType.radial:
        shapeParams = [
          slot.radialCenterX,
          slot.radialCenterY,
          slot.radialRadiusX,
          slot.radialRadiusY,
          slot.radialFeather,
        ];
        break;
      case MaskShapeType.brush:
      case MaskShapeType.ai:
        shapeParams = [0, 0, 0, 0, 0];
        break;
      case MaskShapeType.luminanceRange:
        shapeParams = [slot.lumLow, slot.lumHigh, slot.lumSmoothness, 0, 0];
        break;
      case MaskShapeType.colorRange:
        shapeParams = [
          slot.colorR,
          slot.colorG,
          slot.colorB,
          slot.colorTolerance,
          0,
        ];
        break;
    }
    return [
      typeValue,
      slot.invert ? 1.0 : 0.0,
      ...shapeParams,
      slot.exposure / 100,
      slot.contrast / 100,
      slot.saturation / 100,
      slot.warmth / 100,
    ];
  }

  Map<String, dynamic> toJson() => {
        'exposure': exposure,
        'contrast': contrast,
        'highlights': highlights,
        'shadows': shadows,
        'whites': whites,
        'blacks': blacks,
        'brightness': brightness,
        'saturation': saturation,
        'vibrance': vibrance,
        'warmth': warmth,
        'tint': tint,
        'curves': curves.toJson(),
        'colorGrade': colorGrade.toJson(),
        'blur': blur.toJson(),
        'effects': effects.toJson(),
        'crop': crop.toJson(),
        'heal': heal.toJson(),
        'masking': masking.toJson(),
      };

  factory EditState.fromJson(Map<String, dynamic> json) {
    double read(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return EditState(
      exposure: read('exposure'),
      contrast: read('contrast'),
      highlights: read('highlights'),
      shadows: read('shadows'),
      whites: read('whites'),
      blacks: read('blacks'),
      brightness: read('brightness'),
      saturation: read('saturation'),
      vibrance: read('vibrance'),
      warmth: read('warmth'),
      tint: read('tint'),
      curves: CurvesState.fromJson(json['curves'] as Map<String, dynamic>?),
      colorGrade: ColorGradeState.fromJson(json['colorGrade'] as Map<String, dynamic>?),
      blur: BlurState.fromJson(json['blur'] as Map<String, dynamic>?),
      effects: EffectsState.fromJson(json['effects'] as Map<String, dynamic>?),
      crop: CropState.fromJson(json['crop'] as Map<String, dynamic>?),
      heal: HealState.fromJson(json['heal'] as Map<String, dynamic>?),
      masking: MaskingState.fromJson(json['masking'] as Map<String, dynamic>?),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EditState &&
          runtimeType == other.runtimeType &&
          exposure == other.exposure &&
          contrast == other.contrast &&
          highlights == other.highlights &&
          shadows == other.shadows &&
          whites == other.whites &&
          blacks == other.blacks &&
          brightness == other.brightness &&
          saturation == other.saturation &&
          vibrance == other.vibrance &&
          warmth == other.warmth &&
          tint == other.tint &&
          curves == other.curves &&
          colorGrade == other.colorGrade &&
          blur == other.blur &&
          effects == other.effects &&
          crop == other.crop &&
          heal == other.heal &&
          masking == other.masking;

  @override
  int get hashCode => Object.hash(
        exposure,
        contrast,
        highlights,
        shadows,
        whites,
        blacks,
        brightness,
        saturation,
        vibrance,
        warmth,
        tint,
        curves,
        colorGrade,
        blur,
        effects,
        crop,
        heal,
        masking,
      );
}

enum AdjustmentType {
  exposure,
  contrast,
  highlights,
  shadows,
  whites,
  blacks,
  brightness,
  saturation,
  vibrance,
  warmth,
  tint,
}

extension AdjustmentTypeX on AdjustmentType {
  String get label {
    switch (this) {
      case AdjustmentType.exposure:
        return 'Exposure';
      case AdjustmentType.contrast:
        return 'Contrast';
      case AdjustmentType.highlights:
        return 'Highlights';
      case AdjustmentType.shadows:
        return 'Shadows';
      case AdjustmentType.whites:
        return 'Whites';
      case AdjustmentType.blacks:
        return 'Blacks';
      case AdjustmentType.brightness:
        return 'Brightness';
      case AdjustmentType.saturation:
        return 'Saturation';
      case AdjustmentType.vibrance:
        return 'Vibrance';
      case AdjustmentType.warmth:
        return 'Warmth';
      case AdjustmentType.tint:
        return 'Tint';
    }
  }

  double valueOf(EditState s) {
    switch (this) {
      case AdjustmentType.exposure:
        return s.exposure;
      case AdjustmentType.contrast:
        return s.contrast;
      case AdjustmentType.highlights:
        return s.highlights;
      case AdjustmentType.shadows:
        return s.shadows;
      case AdjustmentType.whites:
        return s.whites;
      case AdjustmentType.blacks:
        return s.blacks;
      case AdjustmentType.brightness:
        return s.brightness;
      case AdjustmentType.saturation:
        return s.saturation;
      case AdjustmentType.vibrance:
        return s.vibrance;
      case AdjustmentType.warmth:
        return s.warmth;
      case AdjustmentType.tint:
        return s.tint;
    }
  }

  EditState apply(EditState s, double value) {
    switch (this) {
      case AdjustmentType.exposure:
        return s.copyWith(exposure: value);
      case AdjustmentType.contrast:
        return s.copyWith(contrast: value);
      case AdjustmentType.highlights:
        return s.copyWith(highlights: value);
      case AdjustmentType.shadows:
        return s.copyWith(shadows: value);
      case AdjustmentType.whites:
        return s.copyWith(whites: value);
      case AdjustmentType.blacks:
        return s.copyWith(blacks: value);
      case AdjustmentType.brightness:
        return s.copyWith(brightness: value);
      case AdjustmentType.saturation:
        return s.copyWith(saturation: value);
      case AdjustmentType.vibrance:
        return s.copyWith(vibrance: value);
      case AdjustmentType.warmth:
        return s.copyWith(warmth: value);
      case AdjustmentType.tint:
        return s.copyWith(tint: value);
    }
  }
}
