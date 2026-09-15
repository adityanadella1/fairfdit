import 'package:flutter/foundation.dart';

/// Linear and Radial are purely procedural (position/size only, computed
/// directly in the shader — no texture needed). Brush and Ai are both
/// texture-backed: Brush's texture is painted by hand, Ai's comes back
/// from the segmentation service. They share the shader's texture path
/// because, once a mask exists, where it came from is irrelevant to
/// rendering — only to how it gets refreshed.
enum MaskShapeType { linear, radial, brush, ai, luminanceRange, colorRange }

/// What an AI mask asked the segmentation service for. Kept on the slot
/// so the mask can be regenerated after a crop or a model upgrade without
/// making the user re-pick the target.
enum AiMaskMode { subject, person, object, background, sky }

extension AiMaskModeX on AiMaskMode {
  /// Wire value for POST /v1/segment — must match the backend's
  /// SegmentMode enum.
  String get wireName => name;

  String get label => switch (this) {
        AiMaskMode.subject => 'Subject',
        AiMaskMode.person => 'People',
        AiMaskMode.object => 'Object',
        AiMaskMode.background => 'Background',
        AiMaskMode.sky => 'Sky',
      };

  /// Only Object needs the user to say *which* object; the rest are
  /// fully determined by the mode itself.
  bool get needsPrompt => this == AiMaskMode.object;
}

/// One local-adjustment mask: a shape (defining WHERE the adjustments
/// apply) plus a focused set of adjustments (WHAT changes there).
/// Linear/Radial fields are only meaningful for their own [type] — kept
/// as plain doubles with sensible defaults rather than nullable, so
/// switching a mask's type later doesn't lose already-reasonable values.
@immutable
class MaskSlot {
  final String id; // stable, so brush textures can be filed as mask_<id>.png
  final MaskShapeType type;
  final bool invert;

  /// Hides this mask's contribution without deleting it — the local
  /// equivalent of Blur's Apply switch, for A/B-ing one mask.
  final bool enabled;

  // AI masks only. [aiMode] is what was asked for, [aiPrompt] the noun
  // for object mode, and [aiPending] is true between requesting a mask
  // and the texture arriving (the slot exists but renders as empty).
  final AiMaskMode? aiMode;
  final String aiPrompt;
  final bool aiPending;

  // Linear gradient — a line from (startX,startY) to (endX,endY); no
  // effect at start, full effect at end, smooth transition between.
  final double linearStartX;
  final double linearStartY;
  final double linearEndX;
  final double linearEndY;

  // Radial gradient — an ellipse; full effect inside, feathered falloff
  // to none at/beyond the edge (or the reverse, with invert).
  final double radialCenterX;
  final double radialCenterY;
  final double radialRadiusX;
  final double radialRadiusY;
  final double radialFeather;

  // Luminance range — selects by brightness. [lumLow] and [lumHigh]
  // bound the band (0 = black, 1 = white) and [lumSmoothness] softens
  // both edges.
  final double lumLow;
  final double lumHigh;
  final double lumSmoothness;

  // Colour range — selects by similarity to a sampled colour. The target
  // is stored as linear 0..1 RGB; [colorTolerance] is how far from it
  // still counts.
  final double colorR;
  final double colorG;
  final double colorB;
  final double colorTolerance;

  /// False until the user has actually sampled a colour, so the panel can
  /// prompt for one instead of showing an arbitrary default selection.
  final bool colorSampled;

  // Local adjustments — deliberately a focused subset (not the full
  // global adjustment panel) to keep the per-mask editor simple.
  final double exposure;
  final double contrast;
  final double saturation;
  final double warmth;

  const MaskSlot({
    required this.id,
    required this.type,
    this.invert = false,
    this.enabled = true,
    this.aiMode,
    this.aiPrompt = '',
    this.aiPending = false,
    this.linearStartX = 0.5,
    this.linearStartY = 0.25,
    this.linearEndX = 0.5,
    this.linearEndY = 0.75,
    this.radialCenterX = 0.5,
    this.radialCenterY = 0.5,
    this.radialRadiusX = 0.3,
    this.radialRadiusY = 0.3,
    this.radialFeather = 0.5,
    // Defaults to the shadows rather than the full range: a mask that
    // selects everything on creation looks identical to a global edit,
    // which teaches the user nothing about what the control does.
    this.lumLow = 0.0,
    this.lumHigh = 0.45,
    this.lumSmoothness = 0.25,
    this.colorR = 0.5,
    this.colorG = 0.5,
    this.colorB = 0.5,
    this.colorTolerance = 0.25,
    this.colorSampled = false,
    this.exposure = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.warmth = 0,
  });

  bool get hasAdjustments => exposure != 0 || contrast != 0 || saturation != 0 || warmth != 0;

  /// What the mask is called in the list. AI masks name themselves after
  /// what they selected ("Object · dog") since a photo can easily hold
  /// three AI masks and "Ai 1/2/3" tells the user nothing.
  String get typeLabel {
    switch (type) {
      case MaskShapeType.linear:
        return 'Linear Gradient';
      case MaskShapeType.radial:
        return 'Radial Gradient';
      case MaskShapeType.brush:
        return 'Brush';
      case MaskShapeType.luminanceRange:
        return 'Luminance Range';
      case MaskShapeType.colorRange:
        return 'Color Range';
      case MaskShapeType.ai:
        final mode = aiMode;
        if (mode == null) return 'AI Mask';
        if (mode == AiMaskMode.object && aiPrompt.isNotEmpty) {
          return 'Object · $aiPrompt';
        }
        return mode.label;
    }
  }

  /// True for the two types whose coverage comes from a texture rather
  /// than from shape parameters.
  bool get isTextureBacked =>
      type == MaskShapeType.brush || type == MaskShapeType.ai;

  MaskSlot copyWith({
    bool? invert,
    bool? enabled,
    double? lumLow,
    double? lumHigh,
    double? lumSmoothness,
    double? colorR,
    double? colorG,
    double? colorB,
    double? colorTolerance,
    bool? colorSampled,
    AiMaskMode? aiMode,
    String? aiPrompt,
    bool? aiPending,
    double? linearStartX,
    double? linearStartY,
    double? linearEndX,
    double? linearEndY,
    double? radialCenterX,
    double? radialCenterY,
    double? radialRadiusX,
    double? radialRadiusY,
    double? radialFeather,
    double? exposure,
    double? contrast,
    double? saturation,
    double? warmth,
  }) {
    return MaskSlot(
      id: id,
      type: type,
      invert: invert ?? this.invert,
      enabled: enabled ?? this.enabled,
      aiMode: aiMode ?? this.aiMode,
      aiPrompt: aiPrompt ?? this.aiPrompt,
      aiPending: aiPending ?? this.aiPending,
      linearStartX: linearStartX ?? this.linearStartX,
      linearStartY: linearStartY ?? this.linearStartY,
      linearEndX: linearEndX ?? this.linearEndX,
      linearEndY: linearEndY ?? this.linearEndY,
      radialCenterX: radialCenterX ?? this.radialCenterX,
      radialCenterY: radialCenterY ?? this.radialCenterY,
      radialRadiusX: radialRadiusX ?? this.radialRadiusX,
      radialRadiusY: radialRadiusY ?? this.radialRadiusY,
      radialFeather: radialFeather ?? this.radialFeather,
      lumLow: lumLow ?? this.lumLow,
      lumHigh: lumHigh ?? this.lumHigh,
      lumSmoothness: lumSmoothness ?? this.lumSmoothness,
      colorR: colorR ?? this.colorR,
      colorG: colorG ?? this.colorG,
      colorB: colorB ?? this.colorB,
      colorTolerance: colorTolerance ?? this.colorTolerance,
      colorSampled: colorSampled ?? this.colorSampled,
      exposure: exposure ?? this.exposure,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      warmth: warmth ?? this.warmth,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'invert': invert,
        'enabled': enabled,
        'aiMode': aiMode?.name,
        'aiPrompt': aiPrompt,
        'linearStartX': linearStartX,
        'linearStartY': linearStartY,
        'linearEndX': linearEndX,
        'linearEndY': linearEndY,
        'radialCenterX': radialCenterX,
        'radialCenterY': radialCenterY,
        'radialRadiusX': radialRadiusX,
        'radialRadiusY': radialRadiusY,
        'radialFeather': radialFeather,
        'lumLow': lumLow,
        'lumHigh': lumHigh,
        'lumSmoothness': lumSmoothness,
        'colorR': colorR,
        'colorG': colorG,
        'colorB': colorB,
        'colorTolerance': colorTolerance,
        'colorSampled': colorSampled,
        'exposure': exposure,
        'contrast': contrast,
        'saturation': saturation,
        'warmth': warmth,
      };

  factory MaskSlot.fromJson(Map<String, dynamic> json) {
    double read(String key, double fallback) => (json[key] as num?)?.toDouble() ?? fallback;
    final typeName = json['type'] as String?;
    final type = MaskShapeType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => MaskShapeType.linear,
    );
    return MaskSlot(
      id: json['id'] as String,
      type: type,
      invert: (json['invert'] as bool?) ?? false,
      enabled: (json['enabled'] as bool?) ?? true,
      aiMode: AiMaskMode.values
          .where((m) => m.name == json['aiMode'])
          .firstOrNull,
      aiPrompt: (json['aiPrompt'] as String?) ?? '',
      linearStartX: read('linearStartX', 0.5),
      linearStartY: read('linearStartY', 0.25),
      linearEndX: read('linearEndX', 0.5),
      linearEndY: read('linearEndY', 0.75),
      radialCenterX: read('radialCenterX', 0.5),
      radialCenterY: read('radialCenterY', 0.5),
      radialRadiusX: read('radialRadiusX', 0.3),
      radialRadiusY: read('radialRadiusY', 0.3),
      radialFeather: read('radialFeather', 0.5),
      lumLow: read('lumLow', 0.0),
      lumHigh: read('lumHigh', 0.45),
      lumSmoothness: read('lumSmoothness', 0.25),
      colorR: read('colorR', 0.5),
      colorG: read('colorG', 0.5),
      colorB: read('colorB', 0.5),
      colorTolerance: read('colorTolerance', 0.25),
      colorSampled: (json['colorSampled'] as bool?) ?? false,
      exposure: read('exposure', 0),
      contrast: read('contrast', 0),
      saturation: read('saturation', 0),
      warmth: read('warmth', 0),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MaskSlot &&
          id == other.id &&
          type == other.type &&
          invert == other.invert &&
          enabled == other.enabled &&
          aiMode == other.aiMode &&
          aiPrompt == other.aiPrompt &&
          aiPending == other.aiPending &&
          linearStartX == other.linearStartX &&
          linearStartY == other.linearStartY &&
          linearEndX == other.linearEndX &&
          linearEndY == other.linearEndY &&
          radialCenterX == other.radialCenterX &&
          radialCenterY == other.radialCenterY &&
          radialRadiusX == other.radialRadiusX &&
          radialRadiusY == other.radialRadiusY &&
          radialFeather == other.radialFeather &&
          lumLow == other.lumLow &&
          lumHigh == other.lumHigh &&
          lumSmoothness == other.lumSmoothness &&
          colorR == other.colorR &&
          colorG == other.colorG &&
          colorB == other.colorB &&
          colorTolerance == other.colorTolerance &&
          colorSampled == other.colorSampled &&
          exposure == other.exposure &&
          contrast == other.contrast &&
          saturation == other.saturation &&
          warmth == other.warmth);

  @override
  int get hashCode => Object.hashAll([
        id,
        type,
        invert,
        enabled,
        aiMode,
        aiPrompt,
        aiPending,
        linearStartX,
        linearStartY,
        linearEndX,
        linearEndY,
        radialCenterX,
        radialCenterY,
        radialRadiusX,
        radialRadiusY,
        radialFeather,
        lumLow,
        lumHigh,
        lumSmoothness,
        colorR,
        colorG,
        colorB,
        colorTolerance,
        colorSampled,
        exposure,
        contrast,
        saturation,
        warmth,
      ]);
}

/// A fixed number of simultaneous local-adjustment masks.
///
/// Bounded rather than unbounded because each slot occupies a fixed spot
/// in the shader's uniform layout and costs one texture sampler. This
/// constant is mirrored by the uMask0..5 uniform block in
/// `shaders/edit_shader.frag` — raising it here without adding the
/// matching uniforms there writes past the end of the block.
@immutable
class MaskingState {
  static const maxSlots = 6;

  final List<MaskSlot> slots;

  const MaskingState({this.slots = const []});

  bool get isNeutral => slots.isEmpty;
  bool get isFull => slots.length >= maxSlots;

  MaskingState copyWith({List<MaskSlot>? slots}) {
    return MaskingState(slots: slots ?? this.slots);
  }

  Map<String, dynamic> toJson() => {
        'slots': slots.map((s) => s.toJson()).toList(),
      };

  factory MaskingState.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const MaskingState();
    final raw = json['slots'] as List<dynamic>?;
    if (raw == null) return const MaskingState();
    try {
      return MaskingState(
        slots: raw.map((e) => MaskSlot.fromJson(e as Map<String, dynamic>)).toList(),
      );
    } catch (_) {
      return const MaskingState();
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MaskingState && listEquals(slots, other.slots));

  @override
  int get hashCode => Object.hashAll(slots);
}
