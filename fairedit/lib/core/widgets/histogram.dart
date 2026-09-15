import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

/// Per-channel tonal distribution of the current edit.
///
/// 256 buckets per channel, normalised 0..1 against the tallest bucket
/// across all three.
@immutable
class HistogramData {
  final List<double> red;
  final List<double> green;
  final List<double> blue;
  final List<double> luma;

  /// Fraction of pixels pinned at 0 or 255. Drives the clipping
  /// indicators — the numbers a photographer actually acts on.
  final double shadowClipping;
  final double highlightClipping;

  const HistogramData({
    required this.red,
    required this.green,
    required this.blue,
    required this.luma,
    required this.shadowClipping,
    required this.highlightClipping,
  });

  static final empty = HistogramData(
    red: List.filled(256, 0),
    green: List.filled(256, 0),
    blue: List.filled(256, 0),
    luma: List.filled(256, 0),
    shadowClipping: 0,
    highlightClipping: 0,
  );

  bool get isEmpty => luma.every((v) => v == 0);

  /// Builds a histogram from raw RGBA bytes.
  ///
  /// Runs on whatever isolate the caller provides — it is pure and
  /// allocation-light precisely so it can be handed to `compute()`
  /// without dragging any Flutter types across the boundary.
  static HistogramData fromRgba(Uint8ListLike bytes) {
    final r = List<int>.filled(256, 0);
    final g = List<int>.filled(256, 0);
    final b = List<int>.filled(256, 0);
    final l = List<int>.filled(256, 0);

    var clippedLow = 0;
    var clippedHigh = 0;
    var counted = 0;

    for (var i = 0; i + 3 < bytes.length; i += 4) {
      // Skip transparent pixels: they are letterboxing around a
      // non-square crop, not image content, and a spike at 0 from them
      // would misreport shadow clipping.
      if (bytes[i + 3] < 8) continue;

      final rv = bytes[i];
      final gv = bytes[i + 1];
      final bv = bytes[i + 2];
      r[rv]++;
      g[gv]++;
      b[bv]++;

      // Rec. 709 luma — the weighting that matches perceived brightness,
      // so the grey curve tracks what the eye reads as exposure.
      final lv = (0.2126 * rv + 0.7152 * gv + 0.0722 * bv).round().clamp(0, 255);
      l[lv]++;
      counted++;

      if (rv <= 1 && gv <= 1 && bv <= 1) clippedLow++;
      if (rv >= 254 && gv >= 254 && bv >= 254) clippedHigh++;
    }

    if (counted == 0) return empty;

    // Normalise against the tallest bucket in any channel so the three
    // curves stay comparable to each other.
    var peak = 1;
    for (final channel in [r, g, b]) {
      for (final value in channel) {
        if (value > peak) peak = value;
      }
    }
    List<double> scale(List<int> channel) =>
        [for (final value in channel) value / peak];

    return HistogramData(
      red: scale(r),
      green: scale(g),
      blue: scale(b),
      luma: scale(l),
      shadowClipping: clippedLow / counted,
      highlightClipping: clippedHigh / counted,
    );
  }
}

/// Minimal structural type so [HistogramData.fromRgba] does not need to
/// import dart:typed_data — `Uint8List` satisfies it.
typedef Uint8ListLike = List<int>;

/// The histogram readout.
///
/// Sits above the tool rail because it is a *reference*, not a control:
/// you glance at it while dragging Exposure to see the shadows approach
/// the left wall. Put it in a panel and it is invisible exactly when it
/// matters.
class HistogramView extends StatelessWidget {
  final HistogramData data;
  final double height;

  /// Shows the clipping percentages and the channel legend. Off in
  /// compact placements.
  final bool showReadout;

  const HistogramView({
    super.key,
    required this.data,
    this.height = 52,
    this.showReadout = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(AppLayout.radiusSm),
        border: Border.all(color: AppColors.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _HistogramPainter(data)),
          ),
          if (showReadout && !data.isEmpty) ...[
            // Clipping warnings sit in the corners they describe, so the
            // indicator is where the problem is.
            if (data.shadowClipping > 0.002)
              Positioned(
                left: 5,
                top: 4,
                child: _ClipBadge(
                  fraction: data.shadowClipping,
                  align: TextAlign.left,
                ),
              ),
            if (data.highlightClipping > 0.002)
              Positioned(
                right: 5,
                top: 4,
                child: _ClipBadge(
                  fraction: data.highlightClipping,
                  align: TextAlign.right,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ClipBadge extends StatelessWidget {
  final double fraction;
  final TextAlign align;

  const _ClipBadge({required this.fraction, required this.align});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        '${(fraction * 100).toStringAsFixed(fraction < 0.1 ? 1 : 0)}%',
        textAlign: align,
        style: AppText.hint.copyWith(
          color: AppColors.danger,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  final HistogramData data;

  const _HistogramPainter(this.data);

  /// Additive blending, so where all three channels overlap the result
  /// reads as white/grey — the same convention every photo editor uses,
  /// and the reason a neutral image shows a single grey mountain rather
  /// than three coloured ones.
  static const _channelColors = [
    Color(0xFFFF4D4D),
    Color(0xFF4DE07A),
    Color(0xFF4D9CFF),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Quarter-tone guides: the reference grid for reading where the
    // midpoint and the quarter tones sit.
    final guide = Paint()
      ..color = AppColors.divider.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), guide);
    }

    if (data.isEmpty) return;

    final channels = [data.red, data.green, data.blue];
    for (var index = 0; index < channels.length; index++) {
      canvas.drawPath(
        _pathFor(channels[index], size),
        Paint()
          ..color = _channelColors[index].withValues(alpha: 0.55)
          ..style = PaintingStyle.fill
          ..blendMode = BlendMode.plus,
      );
    }

    // Luma outline on top — the curve you actually judge exposure by.
    canvas.drawPath(
      _pathFor(data.luma, size, closed: false),
      Paint()
        ..color = AppColors.textPrimary.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );
  }

  /// Builds the filled silhouette for one channel.
  ///
  /// Buckets are smoothed over a 3-wide window: a 256-bucket histogram
  /// drawn into ~200px of width is noisy enough that raw buckets read as
  /// static rather than as a distribution.
  Path _pathFor(List<double> buckets, Size size, {bool closed = true}) {
    final path = Path();
    final step = size.width / 255.0;

    double smoothed(int i) {
      final lo = math.max(0, i - 1);
      final hi = math.min(255, i + 1);
      var sum = 0.0;
      for (var j = lo; j <= hi; j++) {
        sum += buckets[j];
      }
      return sum / (hi - lo + 1);
    }

    // Square root compresses the peaks. A real photo's histogram is
    // dominated by one or two huge buckets, and plotted linearly
    // everything else flattens into the baseline.
    double heightAt(int i) => size.height * math.sqrt(smoothed(i).clamp(0, 1));

    path.moveTo(0, size.height - heightAt(0));
    for (var i = 1; i <= 255; i++) {
      path.lineTo(i * step, size.height - heightAt(i));
    }

    if (closed) {
      path
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
    }
    return path;
  }

  @override
  bool shouldRepaint(_HistogramPainter old) => old.data != data;
}
