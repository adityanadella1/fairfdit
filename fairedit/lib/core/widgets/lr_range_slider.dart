import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

/// A two-handle band selector, for parameters that are a *range* rather
/// than a value — the luminance band a mask covers, primarily.
///
/// Shares [LrSlider]'s relative-drag rule: grabbing a handle moves it by
/// how far the finger travels, never jumping it to the touch point. The
/// handle picked up is whichever is nearer the touch, which is the only
/// workable way to hit one of two handles that may be a few pixels apart.
///
/// The track is painted with the gradient the range selects *over*, so a
/// luminance range shows black-to-white behind its handles and the
/// control explains itself.
class LrRangeSlider extends StatefulWidget {
  final String label;

  /// Both in 0..1, with [low] <= [high] enforced by a minimum gap.
  final double low;
  final double high;

  final void Function(double low, double high) onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;

  /// Painted behind the handles. Two or more stops.
  final List<Color> trackGradient;

  /// What double-tap restores.
  final double defaultLow;
  final double defaultHigh;

  final bool enabled;

  const LrRangeSlider({
    super.key,
    required this.label,
    required this.low,
    required this.high,
    required this.onChanged,
    required this.trackGradient,
    this.onChangeStart,
    this.onChangeEnd,
    this.defaultLow = 0.0,
    this.defaultHigh = 1.0,
    this.enabled = true,
  });

  /// Closer than this and the two handles become one unhittable target.
  static const minGap = 0.04;

  @override
  State<LrRangeSlider> createState() => _LrRangeSliderState();
}

enum _Handle { low, high }

class _LrRangeSliderState extends State<LrRangeSlider> {
  _Handle? _dragging;
  double _dragLow = 0;
  double _dragHigh = 1;

  void _begin(Offset localPosition, double trackWidth) {
    if (!widget.enabled) return;
    _dragLow = widget.low;
    _dragHigh = widget.high;

    // Pick the nearer handle. With a 4% minimum gap the two can sit
    // close together, and "whichever you were reaching for" is better
    // guessed by proximity than by any fixed hit rectangle.
    final touch = (localPosition.dx / trackWidth).clamp(0.0, 1.0);
    final handle = (touch - widget.low).abs() <= (touch - widget.high).abs()
        ? _Handle.low
        : _Handle.high;

    setState(() => _dragging = handle);
    widget.onChangeStart?.call();
  }

  void _update(double deltaX, double trackWidth) {
    if (!widget.enabled || _dragging == null || trackWidth <= 0) return;
    final delta = deltaX / trackWidth;

    if (_dragging == _Handle.low) {
      _dragLow = (_dragLow + delta)
          .clamp(0.0, _dragHigh - LrRangeSlider.minGap);
    } else {
      _dragHigh = (_dragHigh + delta)
          .clamp(_dragLow + LrRangeSlider.minGap, 1.0);
    }
    widget.onChanged(_dragLow, _dragHigh);
  }

  void _end() {
    if (_dragging == null) return;
    setState(() => _dragging = null);
    widget.onChangeEnd?.call();
  }

  void _reset() {
    if (!widget.enabled) return;
    if (widget.low == widget.defaultLow && widget.high == widget.defaultHigh) {
      return;
    }
    HapticFeedback.selectionClick();
    widget.onChangeStart?.call();
    widget.onChanged(widget.defaultLow, widget.defaultHigh);
    widget.onChangeEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.label,
      value: '${(widget.low * 100).round()} to ${(widget.high * 100).round()}',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final trackWidth = math.max(1.0, constraints.maxWidth);

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: _reset,
            onHorizontalDragStart: (d) =>
                _begin(Offset(d.localPosition.dx, 0), trackWidth),
            onHorizontalDragUpdate: (d) => _update(d.delta.dx, trackWidth),
            onHorizontalDragEnd: (_) => _end(),
            onHorizontalDragCancel: _end,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.label,
                          style: AppText.control.copyWith(
                            color: widget.enabled
                                ? AppColors.textPrimary
                                : AppColors.textDisabled,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${(widget.low * 100).round()}–'
                        '${(widget.high * 100).round()}',
                        style: AppText.value.copyWith(
                          color: widget.enabled
                              ? AppColors.textPrimary
                              : AppColors.textDisabled,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  SizedBox(
                    height: 20,
                    child: CustomPaint(
                      painter: _RangeTrackPainter(
                        low: widget.low,
                        high: widget.high,
                        gradient: widget.trackGradient,
                        enabled: widget.enabled,
                        dragging: _dragging,
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

class _RangeTrackPainter extends CustomPainter {
  final double low;
  final double high;
  final List<Color> gradient;
  final bool enabled;
  final _Handle? dragging;

  const _RangeTrackPainter({
    required this.low,
    required this.high,
    required this.gradient,
    required this.enabled,
    required this.dragging,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const handleRadius = 7.0;
    final usable = size.width - handleRadius * 2;
    final cy = size.height / 2;
    const barHeight = 6.0;

    double x(double v) => handleRadius + v.clamp(0.0, 1.0) * usable;

    final trackRect = Rect.fromLTRB(
      handleRadius,
      cy - barHeight / 2,
      handleRadius + usable,
      cy + barHeight / 2,
    );
    final trackRRect = RRect.fromRectAndRadius(
      trackRect,
      const Radius.circular(barHeight / 2),
    );

    canvas.drawRRect(
      trackRRect,
      Paint()..shader = LinearGradient(colors: gradient).createShader(trackRect),
    );

    // Dim what falls outside the band. Showing the unselected region as
    // *darkened gradient* rather than as flat grey keeps the whole track
    // readable as a scale while still making the selection obvious.
    final scrim = Paint()..color = AppColors.canvas.withValues(alpha: 0.68);
    canvas.save();
    canvas.clipRRect(trackRRect);
    canvas.drawRect(
      Rect.fromLTRB(trackRect.left, trackRect.top, x(low), trackRect.bottom),
      scrim,
    );
    canvas.drawRect(
      Rect.fromLTRB(x(high), trackRect.top, trackRect.right, trackRect.bottom),
      scrim,
    );
    canvas.restore();

    for (final (handle, value) in [(_Handle.low, low), (_Handle.high, high)]) {
      final active = dragging == handle;
      final radius = active ? handleRadius + 1 : handleRadius;
      final centre = Offset(x(value), cy);

      if (active) {
        canvas.drawCircle(
          centre,
          radius + 7,
          Paint()..color = AppColors.accent.withValues(alpha: 0.22),
        );
      }
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..color = enabled ? AppColors.sliderThumb : AppColors.textDisabled,
      );
      // Dark ring: a white handle vanishes against the pale end of a
      // black-to-white track without one.
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..color = AppColors.canvas.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3,
      );
    }
  }

  @override
  bool shouldRepaint(_RangeTrackPainter old) =>
      old.low != low ||
      old.high != high ||
      old.enabled != enabled ||
      old.dragging != dragging ||
      old.gradient != gradient;
}
