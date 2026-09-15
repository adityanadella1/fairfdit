import 'package:flutter/foundation.dart';

/// Spot-heal / blemish removal. Deliberately simple — no coordinates or
/// mask data live here (that's a texture, managed by EditProvider and
/// persisted as heal_mask.png/heal_result.png, same pattern as the
/// subject-segmentation mask). This just tracks whether anything has
/// been healed yet, and the brush size preference.
@immutable
class HealState {
  final bool isActive;
  final double brushSize; // 0..100

  const HealState({this.isActive = false, this.brushSize = 40});

  bool get isNeutral => !isActive;

  HealState copyWith({bool? isActive, double? brushSize}) {
    return HealState(
      isActive: isActive ?? this.isActive,
      brushSize: brushSize ?? this.brushSize,
    );
  }

  Map<String, dynamic> toJson() => {'isActive': isActive, 'brushSize': brushSize};

  factory HealState.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const HealState();
    return HealState(
      isActive: (json['isActive'] as bool?) ?? false,
      brushSize: (json['brushSize'] as num?)?.toDouble() ?? 40,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HealState && isActive == other.isActive && brushSize == other.brushSize);

  @override
  int get hashCode => Object.hash(isActive, brushSize);
}
