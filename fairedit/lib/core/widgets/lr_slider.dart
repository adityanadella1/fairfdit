import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

/// A Lightroom-style parameter slider.
///
/// Three behaviours separate this from a Material [Slider] and are the
/// reason it exists:
///
/// * **Relative drag.** Touching the track never jumps the value to the
///   touch point — the value moves by how far the finger travels. On a
///   phone, absolute-positioning a precision control with a fingertip
///   destroys whatever value the user had; relative drag means you can
///   grab anywhere and nudge.
/// * **Fill from the origin.** Bipolar parameters (exposure, contrast…)
///   fill outward from zero rather than from the left edge, so "how far
///   from neutral am I" is readable at a glance.
/// * **Double-tap to reset** this one parameter to its default, which is
///   the only fast way back to neutral without hunting for a Reset that
///   clears the whole panel.
class LrSlider extends StatefulWidget {
  final String label;
  final double value;
  final double min;
  final double max;

  /// Where the fill starts and what double-tap returns to. Defaults to 0
  /// for bipolar ranges and to [min] for unipolar ones.
  final double? origin;

  /// Called once when a drag begins — the hook for pushing an undo entry
  /// so a whole drag is one undo step, not one per frame.
  final VoidCallback? onChangeStart;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeEnd;

  /// Suffix on the numeric readout, e.g. the degree sign.
  final String unit;

  /// Shown in place of the number when the value is at [origin]. Lets a
  /// control read "Auto"/"Off" at rest.
  final String? restLabel;

  final bool enabled;

  /// Paints the track as a colour ramp instead of flat grey.
  ///
  /// For the parameters whose axis *is* a colour — Temperature runs blue
  /// to amber, Tint green to magenta — the ramp turns the control into a
  /// legend for itself. You stop reading "-40" and start reading "toward
  /// blue", which is the judgement you were making anyway.
  final List<Color>? trackGradient;

  const LrSlider({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = -100,
    this.max = 100,
    this.origin,
    this.onChangeStart,
    this.onChangeEnd,
    this.unit = '',
    this.restLabel,
    this.enabled = true,
    this.trackGradient,
  });

  double get effectiveOrigin => origin ?? (min < 0 ? 0.0 : min);

  @override
  State<LrSlider> createState() => _LrSliderState();
}

class _LrSliderState extends State<LrSlider> {
  bool _dragging = false;

  /// Live value during a drag. The parent rebuilds us from its own state
  /// on every onChanged, but we accumulate here so sub-pixel finger
  /// movement is not lost to repeated rounding through the parent.
  double _dragValue = 0;

  void _begin() {
    if (!widget.enabled) return;
    _dragValue = widget.value;
    setState(() => _dragging = true);
    widget.onChangeStart?.call();
  }

  void _update(double deltaX, double trackWidth) {
    if (!widget.enabled || trackWidth <= 0) return;
    final range = widget.max - widget.min;
    _dragValue =
        (_dragValue + deltaX / trackWidth * range).clamp(widget.min, widget.max);
    widget.onChanged(_dragValue);
  }

  void _end() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onChangeEnd?.call();
  }

  void _reset() {
    if (!widget.enabled) return;
    if (widget.value == widget.effectiveOrigin) return;
    HapticFeedback.selectionClick();
    widget.onChangeStart?.call();
    widget.onChanged(widget.effectiveOrigin);
    widget.onChangeEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final atRest = (widget.value - widget.effectiveOrigin).abs() < 0.005;
    final labelColor = !widget.enabled
        ? AppColors.textDisabled
        : atRest
            ? AppColors.textSecondary
            : AppColors.textPrimary;
    final valueColor = !widget.enabled
        ? AppColors.textDisabled
        : atRest
            ? AppColors.textTertiary
            : AppColors.textPrimary;

    return Semantics(
      slider: true,
      label: widget.label,
      value: '${widget.value.round()}${widget.unit}',
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The track now spans the full row, so pixels-to-value for the
          // relative drag converts against the whole width.
          final trackWidth = math.max(1.0, constraints.maxWidth);

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: _reset,
            onHorizontalDragStart: (_) => _begin(),
            onHorizontalDragUpdate: (d) => _update(d.delta.dx, trackWidth),
            onHorizontalDragEnd: (_) => _end(),
            onHorizontalDragCancel: _end,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Label and value share one line, value flush to the
                  // panel edge. A fixed value column beside the track
                  // left a dead channel between the two on every row —
                  // and stole the width the track needed for precision.
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.label,
                          style: AppText.control.copyWith(color: labelColor),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        atRest && widget.restLabel != null
                            ? widget.restLabel!
                            : '${widget.value.round()}${widget.unit}',
                        style: AppText.value.copyWith(color: valueColor),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  SizedBox(
                    height: 18,
                    child: CustomPaint(
                      painter: _LrTrackPainter(
                        value: widget.value,
                        min: widget.min,
                        max: widget.max,
                        origin: widget.effectiveOrigin,
                        enabled: widget.enabled,
                        dragging: _dragging,
                        gradient: widget.trackGradient,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LrTrackPainter extends CustomPainter {
  final double value;
  final double min;
  final double max;
  final double origin;
  final bool enabled;
  final bool dragging;
  final List<Color>? gradient;

  const _LrTrackPainter({
    required this.value,
    required this.min,
    required this.max,
    required this.origin,
    required this.enabled,
    required this.dragging,
    this.gradient,
  });

  double _fraction(double v) => ((v - min) / (max - min)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    const trackHeight = 2.0;
    final thumbRadius = dragging ? 8.0 : 6.5;
    // Inset so the thumb never clips at either end of the track.
    final usable = size.width - thumbRadius * 2;
    final cy = size.height / 2;

    double x(double v) => thumbRadius + _fraction(v) * usable;

    final ramp = gradient;
    // A colour ramp is thicker than a plain track: at 2px the hues are
    // too thin to actually read as colour.
    final barHeight = ramp != null ? 5.0 : trackHeight;
    final trackRect = Rect.fromLTRB(
      thumbRadius,
      cy - barHeight / 2,
      thumbRadius + usable,
      cy + barHeight / 2,
    );
    final trackRRect = RRect.fromRectAndRadius(
      trackRect,
      Radius.circular(barHeight / 2),
    );

    if (ramp != null) {
      canvas.drawRRect(
        trackRRect,
        Paint()
          ..shader = LinearGradient(colors: ramp).createShader(trackRect)
          // Disabled ramps desaturate rather than vanish, so the control
          // still reads as "this one is about colour".
          ..colorFilter = enabled
              ? null
              : const ColorFilter.matrix(<double>[
                  0.2126, 0.7152, 0.0722, 0, 0,
                  0.2126, 0.7152, 0.0722, 0, 0,
                  0.2126, 0.7152, 0.0722, 0, 0,
                  0, 0, 0, 0.5, 0,
                ]),
      );
    } else {
      canvas.drawRRect(trackRRect, Paint()..color = AppColors.sliderInactive);
    }

    final originX = x(origin);
    final valueX = x(value);

    // Fill runs origin -> value, so a bipolar slider grows out of the
    // centre in whichever direction the user pushed it. A ramp track is
    // already showing its own value, so it gets no fill on top.
    if (ramp == null && (valueX - originX).abs() > 0.5) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          math.min(originX, valueX),
          cy - trackHeight / 2,
          math.max(originX, valueX),
          cy + trackHeight / 2,
          const Radius.circular(trackHeight / 2),
        ),
        Paint()
          ..color = enabled ? AppColors.sliderActive : AppColors.textDisabled,
      );
    }

    // Origin tick — only meaningful when the origin sits inside the
    // track rather than at its left edge, and never over a ramp, where
    // it would read as a colour stop.
    if (ramp == null && origin > min + (max - min) * 0.01) {
      canvas.drawRect(
        Rect.fromCenter(center: Offset(originX, cy), width: 1.5, height: 8),
        Paint()..color = AppColors.sliderOrigin,
      );
    }

    if (dragging) {
      canvas.drawCircle(
        Offset(valueX, cy),
        thumbRadius + 7,
        Paint()..color = AppColors.accent.withValues(alpha: 0.20),
      );
    }
    canvas.drawCircle(
      Offset(valueX, cy),
      thumbRadius,
      Paint()..color = enabled ? AppColors.sliderThumb : AppColors.textDisabled,
    );
    if (ramp != null) {
      // A white thumb disappears against the pale middle of a ramp; the
      // dark ring keeps its edge readable across every hue.
      canvas.drawCircle(
        Offset(valueX, cy),
        thumbRadius,
        Paint()
          ..color = AppColors.canvas.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(_LrTrackPainter old) =>
      old.value != value ||
      old.min != min ||
      old.max != max ||
      old.origin != origin ||
      old.enabled != enabled ||
      old.dragging != dragging ||
      old.gradient != gradient;
}
