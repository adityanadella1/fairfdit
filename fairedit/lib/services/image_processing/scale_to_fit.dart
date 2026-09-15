import 'dart:math' as math;

/// Scales (width, height) down so the longer edge is at most
/// [maxDimension], preserving aspect ratio. Never upscales — if the
/// input is already within bounds, returns it unchanged (rounded).
(int, int) fitWithinMaxDimension(num width, num height, num maxDimension) {
  final longSide = math.max(width, height);
  final scale = longSide > maxDimension ? maxDimension / longSide : 1.0;
  return ((width * scale).round().clamp(1, 1 << 30), (height * scale).round().clamp(1, 1 << 30));
}
