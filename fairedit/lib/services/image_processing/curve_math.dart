import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/curves_state.dart';

/// Evaluates a smooth monotone cubic (Fritsch–Carlson) curve through
/// [points] at [resolution] evenly spaced x positions from 0 to 1,
/// returning the corresponding y values (0..1, clamped).
///
/// Monotone cubic — rather than a plain Catmull-Rom / natural cubic
/// spline — is what keeps a tone curve from overshooting past 0 or 1 and
/// producing odd color inversions when two points sit close together.
List<double> evaluateMonotoneCubic(List<CurvePoint> points, int resolution) {
  final sorted = List<CurvePoint>.from(points)..sort((a, b) => a.x.compareTo(b.x));
  final n = sorted.length;
  final result = List<double>.filled(resolution, 0);

  if (n < 2) {
    for (var i = 0; i < resolution; i++) {
      result[i] = resolution == 1 ? 0 : i / (resolution - 1);
    }
    return result;
  }

  final xs = sorted.map((p) => p.x).toList();
  final ys = sorted.map((p) => p.y).toList();

  // Secant slopes between consecutive points.
  final delta = List<double>.filled(n - 1, 0);
  for (var i = 0; i < n - 1; i++) {
    final dx = xs[i + 1] - xs[i];
    delta[i] = dx.abs() < 1e-9 ? 0 : (ys[i + 1] - ys[i]) / dx;
  }

  // Initial tangents.
  final m = List<double>.filled(n, 0);
  m[0] = delta[0];
  m[n - 1] = delta[n - 2];
  for (var i = 1; i < n - 1; i++) {
    m[i] = (delta[i - 1] + delta[i]) / 2;
  }

  // Fritsch–Carlson monotonicity adjustment — prevents overshoot.
  for (var i = 0; i < n - 1; i++) {
    if (delta[i] == 0) {
      m[i] = 0;
      m[i + 1] = 0;
      continue;
    }
    final alpha = m[i] / delta[i];
    final beta = m[i + 1] / delta[i];
    final sumSq = alpha * alpha + beta * beta;
    if (sumSq > 9) {
      final tau = 3 / math.sqrt(sumSq);
      m[i] = tau * alpha * delta[i];
      m[i + 1] = tau * beta * delta[i];
    }
  }

  var segment = 0;
  for (var i = 0; i < resolution; i++) {
    final x = resolution == 1 ? 0.0 : i / (resolution - 1);
    while (segment < n - 2 && x > xs[segment + 1]) {
      segment++;
    }
    final x0 = xs[segment];
    final x1 = xs[segment + 1];
    final dx = x1 - x0;
    final t = dx.abs() < 1e-9 ? 0.0 : ((x - x0) / dx).clamp(0.0, 1.0);

    final t2 = t * t;
    final t3 = t2 * t;
    final h00 = 2 * t3 - 3 * t2 + 1;
    final h10 = t3 - 2 * t2 + t;
    final h01 = -2 * t3 + 3 * t2;
    final h11 = t3 - t2;

    final y = h00 * ys[segment] +
        h10 * dx * m[segment] +
        h01 * ys[segment + 1] +
        h11 * dx * m[segment + 1];

    result[i] = y.clamp(0.0, 1.0);
  }

  return result;
}

/// Builds the 256x1 RGBA byte buffer for the combined tone-curve LUT: for
/// each of the 256 input levels, applies the master curve, then looks up
/// the per-channel curve's output at that intermediate level — storing
/// the three results in the R/G/B bytes of that texel. See
/// shaders/edit_shader.frag for exactly how this gets sampled (one
/// texture read per channel, each at that channel's own input value).
Uint8List buildCurveLutBytes(CurvesState state, {int resolution = 256}) {
  final masterLut = evaluateMonotoneCubic(state.master.points, resolution);
  final redLut = evaluateMonotoneCubic(state.red.points, resolution);
  final greenLut = evaluateMonotoneCubic(state.green.points, resolution);
  final blueLut = evaluateMonotoneCubic(state.blue.points, resolution);

  final bytes = Uint8List(resolution * 4);
  for (var i = 0; i < resolution; i++) {
    final afterMaster = masterLut[i];
    final idx = (afterMaster * (resolution - 1)).round().clamp(0, resolution - 1);

    bytes[i * 4 + 0] = (redLut[idx] * 255).round().clamp(0, 255);
    bytes[i * 4 + 1] = (greenLut[idx] * 255).round().clamp(0, 255);
    bytes[i * 4 + 2] = (blueLut[idx] * 255).round().clamp(0, 255);
    bytes[i * 4 + 3] = 255;
  }
  return bytes;
}
