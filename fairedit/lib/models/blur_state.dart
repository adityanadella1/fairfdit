import 'package:flutter/foundation.dart';

/// Shape of out-of-focus highlights the blur kernel produces. Matches
/// index order the shader expects (uBlurBokehShape encodes this as a
/// plain float 0..4).
enum BokehShape { circular, soapBubble, polygonal, ring, oval }

/// Simulated lens blur: either a focus point the user drags on the photo
/// (distance-based falloff), or — once run — an on-device AI subject
/// mask that keeps the detected subject sharp and blurs everything else.
/// Neither is real depth-sensor data; both are simulations of it.
@immutable
class BlurState {
  final double focusX; // 0..1, normalized image position (point mode)
  final double focusY; // 0..1
  final double amount; // 0..100 — blur strength
  final double size; // 0..100 — radius of the sharp zone (point mode)
  final bool enabled; // master on/off — off keeps amount/settings, just hides the effect
  final BokehShape bokehShape;
  final double catEye; // 0..100 — bokeh stretch toward frame edges
  final double bokehBoost; // 0..100 — brightens out-of-focus highlights
  final bool useSubjectMask; // true once "Select Subject" has been run and is active

  const BlurState({
    this.focusX = 0.5,
    this.focusY = 0.5,
    this.amount = 0,
    this.size = 35,
    this.enabled = true,
    this.bokehShape = BokehShape.circular,
    this.catEye = 0,
    this.bokehBoost = 50,
    this.useSubjectMask = false,
  });

  bool get isNeutral =>
      amount == 0 &&
      enabled == true &&
      bokehShape == BokehShape.circular &&
      catEye == 0 &&
      bokehBoost == 50 &&
      useSubjectMask == false;

  BlurState copyWith({
    double? focusX,
    double? focusY,
    double? amount,
    double? size,
    bool? enabled,
    BokehShape? bokehShape,
    double? catEye,
    double? bokehBoost,
    bool? useSubjectMask,
  }) {
    return BlurState(
      focusX: focusX ?? this.focusX,
      focusY: focusY ?? this.focusY,
      amount: amount ?? this.amount,
      size: size ?? this.size,
      enabled: enabled ?? this.enabled,
      bokehShape: bokehShape ?? this.bokehShape,
      catEye: catEye ?? this.catEye,
      bokehBoost: bokehBoost ?? this.bokehBoost,
      useSubjectMask: useSubjectMask ?? this.useSubjectMask,
    );
  }

  Map<String, dynamic> toJson() => {
        'focusX': focusX,
        'focusY': focusY,
        'amount': amount,
        'size': size,
        'enabled': enabled,
        'bokehShape': bokehShape.name,
        'catEye': catEye,
        'bokehBoost': bokehBoost,
        'useSubjectMask': useSubjectMask,
      };

  factory BlurState.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const BlurState();
    double read(String key, double fallback) => (json[key] as num?)?.toDouble() ?? fallback;
    final shapeName = json['bokehShape'] as String?;
    final shape = BokehShape.values.firstWhere(
      (s) => s.name == shapeName,
      orElse: () => BokehShape.circular,
    );
    return BlurState(
      focusX: read('focusX', 0.5),
      focusY: read('focusY', 0.5),
      amount: read('amount', 0),
      size: read('size', 35),
      enabled: (json['enabled'] as bool?) ?? true,
      bokehShape: shape,
      catEye: read('catEye', 0),
      bokehBoost: read('bokehBoost', 50),
      useSubjectMask: (json['useSubjectMask'] as bool?) ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BlurState &&
          focusX == other.focusX &&
          focusY == other.focusY &&
          amount == other.amount &&
          size == other.size &&
          enabled == other.enabled &&
          bokehShape == other.bokehShape &&
          catEye == other.catEye &&
          bokehBoost == other.bokehBoost &&
          useSubjectMask == other.useSubjectMask);

  @override
  int get hashCode => Object.hash(
        focusX,
        focusY,
        amount,
        size,
        enabled,
        bokehShape,
        catEye,
        bokehBoost,
        useSubjectMask,
      );
}
