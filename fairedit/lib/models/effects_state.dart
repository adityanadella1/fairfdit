import 'package:flutter/foundation.dart';

/// Sharpen, Clarity, Dehaze, Vignette, and Grain — all pure per-pixel or
/// small-neighborhood shader math, no new textures or gestures needed
/// (unlike Curves' LUT or Blur's subject mask).
@immutable
class EffectsState {
  final double sharpen; // 0..100
  final double clarity; // -100..100 — local/midtone contrast
  final double dehaze; // -100..100 — negative adds a haze-like flatness
  final double vignetteAmount; // -100..100 — negative lightens corners instead
  final double vignetteSize; // 0..100 — how far in the falloff starts
  final double grainAmount; // 0..100
  final double grainSize; // 0..100 — larger value = coarser, bigger grain

  const EffectsState({
    this.sharpen = 0,
    this.clarity = 0,
    this.dehaze = 0,
    this.vignetteAmount = 0,
    this.vignetteSize = 50,
    this.grainAmount = 0,
    this.grainSize = 50,
  });

  bool get isNeutral =>
      sharpen == 0 &&
      clarity == 0 &&
      dehaze == 0 &&
      vignetteAmount == 0 &&
      vignetteSize == 50 &&
      grainAmount == 0 &&
      grainSize == 50;

  EffectsState copyWith({
    double? sharpen,
    double? clarity,
    double? dehaze,
    double? vignetteAmount,
    double? vignetteSize,
    double? grainAmount,
    double? grainSize,
  }) {
    return EffectsState(
      sharpen: sharpen ?? this.sharpen,
      clarity: clarity ?? this.clarity,
      dehaze: dehaze ?? this.dehaze,
      vignetteAmount: vignetteAmount ?? this.vignetteAmount,
      vignetteSize: vignetteSize ?? this.vignetteSize,
      grainAmount: grainAmount ?? this.grainAmount,
      grainSize: grainSize ?? this.grainSize,
    );
  }

  Map<String, dynamic> toJson() => {
        'sharpen': sharpen,
        'clarity': clarity,
        'dehaze': dehaze,
        'vignetteAmount': vignetteAmount,
        'vignetteSize': vignetteSize,
        'grainAmount': grainAmount,
        'grainSize': grainSize,
      };

  factory EffectsState.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const EffectsState();
    double read(String key, double fallback) => (json[key] as num?)?.toDouble() ?? fallback;
    return EffectsState(
      sharpen: read('sharpen', 0),
      clarity: read('clarity', 0),
      dehaze: read('dehaze', 0),
      vignetteAmount: read('vignetteAmount', 0),
      vignetteSize: read('vignetteSize', 50),
      grainAmount: read('grainAmount', 0),
      grainSize: read('grainSize', 50),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EffectsState &&
          sharpen == other.sharpen &&
          clarity == other.clarity &&
          dehaze == other.dehaze &&
          vignetteAmount == other.vignetteAmount &&
          vignetteSize == other.vignetteSize &&
          grainAmount == other.grainAmount &&
          grainSize == other.grainSize);

  @override
  int get hashCode =>
      Object.hash(sharpen, clarity, dehaze, vignetteAmount, vignetteSize, grainAmount, grainSize);
}

enum EffectType { sharpen, clarity, dehaze, vignetteAmount, vignetteSize, grainAmount, grainSize }

extension EffectTypeX on EffectType {
  String get label {
    switch (this) {
      case EffectType.sharpen:
        return 'Sharpen';
      case EffectType.clarity:
        return 'Clarity';
      case EffectType.dehaze:
        return 'Dehaze';
      case EffectType.vignetteAmount:
        return 'Vignette';
      case EffectType.vignetteSize:
        return 'Vig. Size';
      case EffectType.grainAmount:
        return 'Grain';
      case EffectType.grainSize:
        return 'Grain Size';
    }
  }

  /// Sharpen/Grain amounts and both "size" controls are 0..100 (no
  /// meaningful negative direction); Clarity/Dehaze/Vignette can go
  /// negative for the opposite effect.
  double get min {
    switch (this) {
      case EffectType.sharpen:
      case EffectType.vignetteSize:
      case EffectType.grainAmount:
      case EffectType.grainSize:
        return 0;
      case EffectType.clarity:
      case EffectType.dehaze:
      case EffectType.vignetteAmount:
        return -100;
    }
  }

  double get max => 100;

  double valueOf(EffectsState s) {
    switch (this) {
      case EffectType.sharpen:
        return s.sharpen;
      case EffectType.clarity:
        return s.clarity;
      case EffectType.dehaze:
        return s.dehaze;
      case EffectType.vignetteAmount:
        return s.vignetteAmount;
      case EffectType.vignetteSize:
        return s.vignetteSize;
      case EffectType.grainAmount:
        return s.grainAmount;
      case EffectType.grainSize:
        return s.grainSize;
    }
  }

  EffectsState apply(EffectsState s, double value) {
    switch (this) {
      case EffectType.sharpen:
        return s.copyWith(sharpen: value);
      case EffectType.clarity:
        return s.copyWith(clarity: value);
      case EffectType.dehaze:
        return s.copyWith(dehaze: value);
      case EffectType.vignetteAmount:
        return s.copyWith(vignetteAmount: value);
      case EffectType.vignetteSize:
        return s.copyWith(vignetteSize: value);
      case EffectType.grainAmount:
        return s.copyWith(grainAmount: value);
      case EffectType.grainSize:
        return s.copyWith(grainSize: value);
    }
  }
}
