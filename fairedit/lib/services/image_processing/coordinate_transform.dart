import 'dart:math' as math;
import 'dart:ui';

import '../../models/crop_state.dart';

/// Dart-side mirror of the shader's mapOutputToRaw() (see
/// edit_shader.frag) — converts a normalized point in the CURRENT
/// (post-crop) output frame into the corresponding normalized point in
/// the original raw image.
///
/// Needed whenever a UI gesture captures a point relative to what's on
/// screen (which reflects any active crop/straighten/rotate/flip) but
/// that point needs to be baked into a mask texture sampled in raw-image
/// space — Heal's brush and Masking's brush type both do this. Without
/// this conversion, a brush mark would land in the wrong place as soon
/// as any crop is active while painting.
Offset mapOutputToRaw(Offset outputUV, CropState crop, double imageAspect) {
  var x = crop.left + (crop.right - crop.left) * outputUV.dx;
  var y = crop.top + (crop.bottom - crop.top) * outputUV.dy;

  if (crop.flipHorizontal) x = 1.0 - x;
  if (crop.flipVertical) y = 1.0 - y;

  final rotated = _undoRotationSteps(Offset(x, y), crop.rotationSteps);
  return _undoStraighten(rotated, crop.straightenAngle * (math.pi / 180.0), imageAspect);
}

Offset _undoRotationSteps(Offset uv, int steps) {
  switch (steps % 4) {
    case 0:
      return uv;
    case 1:
      return Offset(uv.dy, 1.0 - uv.dx);
    case 2:
      return Offset(1.0 - uv.dx, 1.0 - uv.dy);
    default:
      return Offset(1.0 - uv.dy, uv.dx);
  }
}

Offset _undoStraighten(Offset uv, double angleRad, double imageAspect) {
  if (angleRad.abs() < 0.0005) return uv;
  final ca = math.cos(angleRad).abs();
  final sa = math.sin(angleRad).abs();
  final term1 = ca + sa / imageAspect;
  final term2 = imageAspect * sa + ca;
  final scale = math.max(term1, term2);

  // Must match edit_shader.frag's undoStraighten exactly. UV space is
  // anisotropic, so x is scaled into a square space before rotating and
  // back afterwards — rotating in raw UV shears rather than rotates.
  final centeredX = (uv.dx - 0.5) / scale * imageAspect;
  final centeredY = (uv.dy - 0.5) / scale;
  final cosA = math.cos(-angleRad);
  final sinA = math.sin(-angleRad);
  final rotatedX = centeredX * cosA - centeredY * sinA;
  final rotatedY = centeredX * sinA + centeredY * cosA;
  return Offset(rotatedX / imageAspect + 0.5, rotatedY + 0.5);
}
