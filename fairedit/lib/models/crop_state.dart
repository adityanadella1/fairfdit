import 'package:flutter/foundation.dart';

/// Crop + straighten + rotate + flip. Unlike every other feature so far,
/// this one changes the image's own dimensions, so the pipeline order
/// matters: raw -> straighten (small-angle, auto-scaled to avoid empty
/// corners) -> rotationSteps (90 degree turns) -> flip -> crop. left/top/
/// right/bottom are fractions of the frame AFTER straighten+rotate+flip,
/// not of the raw image.
@immutable
class CropState {
  final double left; // 0..1
  final double top;
  final double right; // > left
  final double bottom; // > top
  final double straightenAngle; // -45..45 degrees, positive = clockwise
  final int rotationSteps; // 0..3, each step = 90 degrees clockwise
  final bool flipHorizontal;
  final bool flipVertical;
  final String? aspectPresetLabel; // UI-only memory of which preset is active; not used by the shader

  const CropState({
    this.left = 0,
    this.top = 0,
    this.right = 1,
    this.bottom = 1,
    this.straightenAngle = 0,
    this.rotationSteps = 0,
    this.flipHorizontal = false,
    this.flipVertical = false,
    this.aspectPresetLabel,
  });

  bool get isNeutral =>
      left == 0 &&
      top == 0 &&
      right == 1 &&
      bottom == 1 &&
      straightenAngle == 0 &&
      rotationSteps == 0 &&
      !flipHorizontal &&
      !flipVertical;

  double get cropWidth => right - left;
  double get cropHeight => bottom - top;

  /// Aspect ratio of the frame straighten+rotationSteps produce, BEFORE
  /// crop narrows it further. rotationSteps 1 or 3 swap width/height.
  double preCropAspectRatio(int imageWidth, int imageHeight) {
    final swapped = rotationSteps == 1 || rotationSteps == 3;
    final w = swapped ? imageHeight.toDouble() : imageWidth.toDouble();
    final h = swapped ? imageWidth.toDouble() : imageHeight.toDouble();
    return w / h;
  }

  /// The final output aspect ratio once crop is also applied — what the
  /// editor should actually display (outside of crop-editing mode) and
  /// what export should render at.
  double outputAspectRatio(int imageWidth, int imageHeight) {
    final pre = preCropAspectRatio(imageWidth, imageHeight);
    return (pre * cropWidth) / cropHeight;
  }

  CropState copyWith({
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? straightenAngle,
    int? rotationSteps,
    bool? flipHorizontal,
    bool? flipVertical,
    String? aspectPresetLabel,
    bool clearAspectPresetLabel = false,
  }) {
    return CropState(
      left: left ?? this.left,
      top: top ?? this.top,
      right: right ?? this.right,
      bottom: bottom ?? this.bottom,
      straightenAngle: straightenAngle ?? this.straightenAngle,
      rotationSteps: rotationSteps ?? this.rotationSteps,
      flipHorizontal: flipHorizontal ?? this.flipHorizontal,
      flipVertical: flipVertical ?? this.flipVertical,
      aspectPresetLabel:
          clearAspectPresetLabel ? null : (aspectPresetLabel ?? this.aspectPresetLabel),
    );
  }

  Map<String, dynamic> toJson() => {
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
        'straightenAngle': straightenAngle,
        'rotationSteps': rotationSteps,
        'flipHorizontal': flipHorizontal,
        'flipVertical': flipVertical,
        'aspectPresetLabel': aspectPresetLabel,
      };

  factory CropState.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const CropState();
    double read(String key, double fallback) => (json[key] as num?)?.toDouble() ?? fallback;
    return CropState(
      left: read('left', 0),
      top: read('top', 0),
      right: read('right', 1),
      bottom: read('bottom', 1),
      straightenAngle: read('straightenAngle', 0),
      rotationSteps: (json['rotationSteps'] as num?)?.toInt() ?? 0,
      flipHorizontal: (json['flipHorizontal'] as bool?) ?? false,
      flipVertical: (json['flipVertical'] as bool?) ?? false,
      aspectPresetLabel: json['aspectPresetLabel'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CropState &&
          left == other.left &&
          top == other.top &&
          right == other.right &&
          bottom == other.bottom &&
          straightenAngle == other.straightenAngle &&
          rotationSteps == other.rotationSteps &&
          flipHorizontal == other.flipHorizontal &&
          flipVertical == other.flipVertical &&
          aspectPresetLabel == other.aspectPresetLabel);

  @override
  int get hashCode => Object.hash(
        left,
        top,
        right,
        bottom,
        straightenAngle,
        rotationSteps,
        flipHorizontal,
        flipVertical,
        aspectPresetLabel,
      );
}
