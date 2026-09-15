import 'package:flutter/foundation.dart';

/// One tonal range's grade: a hue/saturation offset (picked from a color
/// wheel — saturation here doubles as "strength", i.e. distance from the
/// wheel's neutral center) plus a luminance nudge for that range.
@immutable
class ColorGradeRange {
  final double hue; // 0..360
  final double saturation; // 0..100 — strength / distance from wheel center
  final double luminance; // -100..100

  const ColorGradeRange({this.hue = 0, this.saturation = 0, this.luminance = 0});

  /// Hue is meaningless at saturation 0, so neutrality only depends on
  /// saturation and luminance.
  bool get isNeutral => saturation == 0 && luminance == 0;

  ColorGradeRange copyWith({double? hue, double? saturation, double? luminance}) {
    return ColorGradeRange(
      hue: hue ?? this.hue,
      saturation: saturation ?? this.saturation,
      luminance: luminance ?? this.luminance,
    );
  }

  Map<String, dynamic> toJson() => {
        'hue': hue,
        'saturation': saturation,
        'luminance': luminance,
      };

  factory ColorGradeRange.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ColorGradeRange();
    double read(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return ColorGradeRange(
      hue: read('hue'),
      saturation: read('saturation'),
      luminance: read('luminance'),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ColorGradeRange &&
          hue == other.hue &&
          saturation == other.saturation &&
          luminance == other.luminance);

  @override
  int get hashCode => Object.hash(hue, saturation, luminance);
}

enum GradeRange { shadows, midtones, highlights }

/// All three tonal ranges for one photo, plus how widely they blend into
/// each other (mirrors Lightroom's "Blending" control).
@immutable
class ColorGradeState {
  final ColorGradeRange shadows;
  final ColorGradeRange midtones;
  final ColorGradeRange highlights;
  final double blending; // 0..100

  const ColorGradeState({
    this.shadows = const ColorGradeRange(),
    this.midtones = const ColorGradeRange(),
    this.highlights = const ColorGradeRange(),
    this.blending = 50,
  });

  bool get isNeutral => shadows.isNeutral && midtones.isNeutral && highlights.isNeutral;

  ColorGradeRange forRange(GradeRange range) {
    switch (range) {
      case GradeRange.shadows:
        return shadows;
      case GradeRange.midtones:
        return midtones;
      case GradeRange.highlights:
        return highlights;
    }
  }

  ColorGradeState withRange(GradeRange range, ColorGradeRange value) {
    switch (range) {
      case GradeRange.shadows:
        return copyWith(shadows: value);
      case GradeRange.midtones:
        return copyWith(midtones: value);
      case GradeRange.highlights:
        return copyWith(highlights: value);
    }
  }

  ColorGradeState copyWith({
    ColorGradeRange? shadows,
    ColorGradeRange? midtones,
    ColorGradeRange? highlights,
    double? blending,
  }) {
    return ColorGradeState(
      shadows: shadows ?? this.shadows,
      midtones: midtones ?? this.midtones,
      highlights: highlights ?? this.highlights,
      blending: blending ?? this.blending,
    );
  }

  Map<String, dynamic> toJson() => {
        'shadows': shadows.toJson(),
        'midtones': midtones.toJson(),
        'highlights': highlights.toJson(),
        'blending': blending,
      };

  factory ColorGradeState.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ColorGradeState();
    return ColorGradeState(
      shadows: ColorGradeRange.fromJson(json['shadows'] as Map<String, dynamic>?),
      midtones: ColorGradeRange.fromJson(json['midtones'] as Map<String, dynamic>?),
      highlights: ColorGradeRange.fromJson(json['highlights'] as Map<String, dynamic>?),
      blending: (json['blending'] as num?)?.toDouble() ?? 50,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ColorGradeState &&
          shadows == other.shadows &&
          midtones == other.midtones &&
          highlights == other.highlights &&
          blending == other.blending);

  @override
  int get hashCode => Object.hash(shadows, midtones, highlights, blending);
}
