import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The editor's own glyph set.
///
/// Material's stock icons are drawn for general-purpose app chrome, and
/// in a photo editor they read as generic — `Icons.tune` is four sliders,
/// which says "settings", not "tone". These are drawn for this app: a
/// consistent 24-unit grid, 1.6 stroke, round caps, so the whole rail
/// looks like one instrument rather than a pick-and-mix from a system
/// font.
///
/// Every glyph is a [Path] on a 24x24 canvas, scaled at paint time, so
/// they stay sharp at any size and tint with a single colour.
enum EditorGlyph {
  // Tool rail
  crop,
  light,
  colorGrade,
  curve,
  effects,
  lensBlur,
  healing,
  masking,

  // Mask types
  subject,
  person,
  object,
  background,
  sky,
  brush,
  linearGradient,
  radialGradient,
  luminanceRange,
  colorRange,

  // Chrome
  histogram,
  compare,
  undo,
  redo,
  export,
}

/// Paints an [EditorGlyph] at [size], tinted [color].
class EditorIcon extends StatelessWidget {
  final EditorGlyph glyph;
  final double size;
  final Color color;

  /// Scales stroke weight with the glyph so a 32px icon does not look
  /// hairline next to a 16px one.
  final double strokeScale;

  const EditorIcon(
    this.glyph, {
    super.key,
    this.size = 22,
    required this.color,
    this.strokeScale = 1,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GlyphPainter(
          glyph: glyph,
          color: color,
          strokeScale: strokeScale,
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  final EditorGlyph glyph;
  final Color color;
  final double strokeScale;

  const _GlyphPainter({
    required this.glyph,
    required this.color,
    required this.strokeScale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Everything below is authored on a 24x24 grid; one scale here keeps
    // each glyph's own code free of size arithmetic.
    final scale = size.width / 24.0;
    canvas.save();
    canvas.scale(scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * strokeScale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (glyph) {
      case EditorGlyph.crop:
        _crop(canvas, stroke);
      case EditorGlyph.light:
        _light(canvas, stroke);
      case EditorGlyph.colorGrade:
        _colorGrade(canvas, stroke, fill);
      case EditorGlyph.curve:
        _curve(canvas, stroke, fill);
      case EditorGlyph.effects:
        _effects(canvas, stroke, fill);
      case EditorGlyph.lensBlur:
        _lensBlur(canvas, stroke, fill);
      case EditorGlyph.healing:
        _healing(canvas, stroke, fill);
      case EditorGlyph.masking:
        _masking(canvas, stroke, fill);
      case EditorGlyph.subject:
        _subject(canvas, stroke, fill);
      case EditorGlyph.person:
        _person(canvas, stroke);
      case EditorGlyph.object:
        _object(canvas, stroke);
      case EditorGlyph.background:
        _background(canvas, stroke);
      case EditorGlyph.sky:
        _sky(canvas, stroke);
      case EditorGlyph.brush:
        _brush(canvas, stroke, fill);
      case EditorGlyph.linearGradient:
        _linearGradient(canvas, stroke);
      case EditorGlyph.radialGradient:
        _radialGradient(canvas, stroke);
      case EditorGlyph.luminanceRange:
        _luminanceRange(canvas, stroke, fill);
      case EditorGlyph.colorRange:
        _colorRange(canvas, stroke, fill);
      case EditorGlyph.histogram:
        _histogram(canvas, fill);
      case EditorGlyph.compare:
        _compare(canvas, stroke, fill);
      case EditorGlyph.undo:
        _undoRedo(canvas, stroke, flip: false);
      case EditorGlyph.redo:
        _undoRedo(canvas, stroke, flip: true);
      case EditorGlyph.export:
        _export(canvas, stroke);
    }

    canvas.restore();
  }

  // --- Tool rail ------------------------------------------------------

  /// Two offset L-brackets — the photographer's crop marks.
  void _crop(Canvas canvas, Paint stroke) {
    canvas.drawPath(
      Path()
        ..moveTo(7, 2)
        ..lineTo(7, 17)
        ..lineTo(22, 17),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(2, 7)
        ..lineTo(17, 7)
        ..lineTo(17, 22),
      stroke,
    );
  }

  /// Sun with rays. Tone control is "how much light", and the sun is the
  /// one symbol nobody has to learn.
  void _light(Canvas canvas, Paint stroke) {
    canvas.drawCircle(const Offset(12, 12), 4.4, stroke);
    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi / 4;
      final dx = math.cos(angle);
      final dy = math.sin(angle);
      canvas.drawLine(
        Offset(12 + dx * 7.4, 12 + dy * 7.4),
        Offset(12 + dx * 9.8, 12 + dy * 9.8),
        stroke,
      );
    }
  }

  /// Three overlapping discs — subtractive colour mixing. One is filled
  /// so the glyph reads at 16px, where three outlines turn to mush.
  void _colorGrade(Canvas canvas, Paint stroke, Paint fill) {
    canvas.drawCircle(
      const Offset(12, 8),
      5.2,
      Paint()
        ..color = fill.color.withValues(alpha: 0.9)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(const Offset(8.4, 14.4), 5.2, stroke);
    canvas.drawCircle(const Offset(15.6, 14.4), 5.2, stroke);
  }

  /// Framed grid with an S-curve and its two end handles — the tone
  /// curve as it actually appears in the panel.
  void _curve(Canvas canvas, Paint stroke, Paint fill) {
    canvas.drawRRect(
      RRect.fromLTRBR(3, 3, 21, 21, const Radius.circular(2.5)),
      Paint()
        ..color = stroke.color.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.strokeWidth * 0.8,
    );
    canvas.drawPath(
      Path()
        ..moveTo(4, 20)
        ..cubicTo(9.5, 20, 8.5, 12, 12, 12)
        ..cubicTo(15.5, 12, 14.5, 4, 20, 4),
      stroke,
    );
    canvas.drawCircle(const Offset(4, 20), 1.7, fill);
    canvas.drawCircle(const Offset(20, 4), 1.7, fill);
  }

  /// A four-point sparkle plus a small companion — the standard
  /// "enhance" mark, and the one users already associate with effects.
  void _effects(Canvas canvas, Paint stroke, Paint fill) {
    Path star(double cx, double cy, double r) {
      final inner = r * 0.34;
      return Path()
        ..moveTo(cx, cy - r)
        ..cubicTo(cx + inner, cy - inner, cx + inner, cy - inner, cx + r, cy)
        ..cubicTo(cx + inner, cy + inner, cx + inner, cy + inner, cx, cy + r)
        ..cubicTo(cx - inner, cy + inner, cx - inner, cy + inner, cx - r, cy)
        ..cubicTo(cx - inner, cy - inner, cx - inner, cy - inner, cx, cy - r)
        ..close();
    }

    canvas.drawPath(star(10, 11, 7.6), fill);
    canvas.drawPath(
      star(18.4, 18, 3.6),
      Paint()
        ..color = fill.color.withValues(alpha: 0.7)
        ..style = PaintingStyle.fill,
    );
  }

  /// Sharp centre, softening outward. The glyph is the effect.
  void _lensBlur(Canvas canvas, Paint stroke, Paint fill) {
    canvas.drawCircle(const Offset(12, 12), 2.4, fill);
    for (final (radius, alpha) in [(5.6, 0.72), (8.4, 0.4), (10.9, 0.18)]) {
      canvas.drawCircle(
        const Offset(12, 12),
        radius,
        Paint()
          ..color = stroke.color.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke.strokeWidth,
      );
    }
  }

  /// A plaster at 45 degrees with its dressing dots — the repair tool.
  void _healing(Canvas canvas, Paint stroke, Paint fill) {
    canvas.save();
    canvas.translate(12, 12);
    canvas.rotate(-math.pi / 4);
    canvas.drawRRect(
      RRect.fromLTRBR(-9.5, -4.6, 9.5, 4.6, const Radius.circular(4.6)),
      stroke,
    );
    canvas.drawLine(const Offset(0, -4.6), const Offset(0, 4.6), stroke);
    for (final dx in [-5.0, 5.0]) {
      for (final dy in [-1.9, 1.9]) {
        canvas.drawCircle(Offset(dx, dy), 0.95, fill);
      }
    }
    canvas.restore();
  }

  /// A frame with a filled circle straddling its edge — selected inside,
  /// unselected outside, which is exactly what a mask does.
  void _masking(Canvas canvas, Paint stroke, Paint fill) {
    canvas.drawRRect(
      RRect.fromLTRBR(2.6, 2.6, 21.4, 21.4, const Radius.circular(3)),
      stroke,
    );
    canvas.save();
    canvas.clipRRect(
      RRect.fromLTRBR(2.6, 2.6, 21.4, 21.4, const Radius.circular(3)),
    );
    canvas.drawCircle(
      const Offset(16, 16),
      7.2,
      Paint()
        ..color = fill.color.withValues(alpha: 0.85)
        ..style = PaintingStyle.fill,
    );
    canvas.restore();
  }

  // --- Mask types ------------------------------------------------------

  /// A person inside a dashed selection — "find the subject for me".
  void _subject(Canvas canvas, Paint stroke, Paint fill) {
    _dashedRect(canvas, stroke, const Rect.fromLTRB(2.4, 2.4, 21.6, 21.6));
    canvas.drawCircle(const Offset(12, 10), 3.1, fill);
    canvas.drawPath(
      Path()
        ..moveTo(6.6, 19.4)
        ..cubicTo(6.6, 15.6, 9.0, 14.0, 12, 14.0)
        ..cubicTo(15.0, 14.0, 17.4, 15.6, 17.4, 19.4),
      Paint()
        ..color = fill.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  void _person(Canvas canvas, Paint stroke) {
    canvas.drawCircle(const Offset(12, 8.4), 3.9, stroke);
    canvas.drawPath(
      Path()
        ..moveTo(4.8, 20.4)
        ..cubicTo(4.8, 16.0, 8.0, 13.8, 12, 13.8)
        ..cubicTo(16.0, 13.8, 19.2, 16.0, 19.2, 20.4),
      stroke,
    );
  }

  /// An isometric cube — a generic "thing", which is what an object
  /// prompt selects.
  void _object(Canvas canvas, Paint stroke) {
    canvas.drawPath(
      Path()
        ..moveTo(12, 2.8)
        ..lineTo(20.8, 7.4)
        ..lineTo(20.8, 16.6)
        ..lineTo(12, 21.2)
        ..lineTo(3.2, 16.6)
        ..lineTo(3.2, 7.4)
        ..close(),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(3.2, 7.4)
        ..lineTo(12, 12)
        ..lineTo(20.8, 7.4)
        ..moveTo(12, 12)
        ..lineTo(12, 21.2),
      Paint()
        ..color = stroke.color.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.strokeWidth
        ..strokeJoin = StrokeJoin.round,
    );
  }

  /// The inverse of [_subject]: frame selected, person punched out.
  void _background(Canvas canvas, Paint stroke) {
    final frame = Path()
      ..addRRect(
        RRect.fromLTRBR(2.6, 2.6, 21.4, 21.4, const Radius.circular(3)),
      );
    final subject = Path()
      ..addOval(const Rect.fromLTRB(8.6, 6.0, 15.4, 12.8))
      ..addRRect(
        RRect.fromLTRBR(6.8, 14.0, 17.2, 24, const Radius.circular(5)),
      );
    canvas.drawPath(
      Path.combine(PathOperation.difference, frame, subject),
      Paint()
        ..color = stroke.color
        ..style = PaintingStyle.fill,
    );
  }

  void _sky(Canvas canvas, Paint stroke) {
    canvas.drawCircle(const Offset(8.2, 8.4), 3.0, stroke);
    canvas.drawPath(
      Path()
        ..moveTo(7.4, 18.6)
        ..cubicTo(4.6, 18.6, 3.2, 16.9, 3.2, 15.1)
        ..cubicTo(3.2, 13.3, 4.8, 11.8, 6.8, 11.9)
        ..cubicTo(7.6, 9.6, 9.8, 8.2, 12.3, 8.6)
        ..cubicTo(14.9, 9.0, 16.8, 11.2, 16.8, 13.6)
        ..cubicTo(19.1, 13.6, 20.8, 15.0, 20.8, 16.8)
        ..cubicTo(20.8, 18.0, 19.8, 18.6, 18.4, 18.6)
        ..close(),
      stroke,
    );
  }

  void _brush(Canvas canvas, Paint stroke, Paint fill) {
    canvas.drawPath(
      Path()
        ..moveTo(19.8, 4.2)
        ..cubicTo(20.8, 5.2, 20.8, 6.4, 19.8, 7.4)
        ..lineTo(12.4, 14.8)
        ..lineTo(9.2, 11.6)
        ..lineTo(16.6, 4.2)
        ..cubicTo(17.6, 3.2, 18.8, 3.2, 19.8, 4.2)
        ..close(),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(8.2, 12.8)
        ..cubicTo(6.2, 13.4, 5.4, 15.2, 5.4, 17.0)
        ..cubicTo(5.4, 18.4, 4.6, 19.4, 3.2, 20.0)
        ..cubicTo(5.4, 21.4, 9.0, 21.0, 10.4, 18.6)
        ..cubicTo(11.3, 17.0, 11.0, 15.2, 9.8, 14.2)
        ..close(),
      fill,
    );
  }

  /// A band of ruled lines thinning downward — a linear falloff.
  void _linearGradient(Canvas canvas, Paint stroke) {
    canvas.drawRRect(
      RRect.fromLTRBR(2.6, 2.6, 21.4, 21.4, const Radius.circular(3)),
      Paint()
        ..color = stroke.color.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.strokeWidth * 0.8,
    );
    var y = 6.4;
    for (final alpha in [1.0, 0.75, 0.5, 0.3, 0.15]) {
      canvas.drawLine(
        Offset(5.6, y),
        Offset(18.4, y),
        Paint()
          ..color = stroke.color.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke.strokeWidth
          ..strokeCap = StrokeCap.round,
      );
      y += 2.6;
    }
  }

  /// Nested ellipses fading outward — a radial falloff.
  void _radialGradient(Canvas canvas, Paint stroke) {
    for (final (radius, alpha) in [(3.2, 1.0), (6.2, 0.6), (9.2, 0.3)]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: const Offset(12, 12),
          width: radius * 2,
          height: radius * 1.7,
        ),
        Paint()
          ..color = stroke.color.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke.strokeWidth,
      );
    }
  }

  /// A black-to-white ramp with a band bracketed out of it — the
  /// control's own track, in miniature.
  void _luminanceRange(Canvas canvas, Paint stroke, Paint fill) {
    const rect = Rect.fromLTRB(2.6, 8.0, 21.4, 16.0);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            fill.color.withValues(alpha: 0.12),
            fill.color.withValues(alpha: 1.0),
          ],
        ).createShader(rect),
    );
    // Bracket marks at the band edges.
    for (final x in [8.4, 15.6]) {
      canvas.drawLine(
        Offset(x, 5.2),
        Offset(x, 18.8),
        Paint()
          ..color = fill.color
          ..strokeWidth = stroke.strokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  /// An eyedropper over a target ring — sample a colour, select its kin.
  void _colorRange(Canvas canvas, Paint stroke, Paint fill) {
    canvas.drawCircle(
      const Offset(9.0, 15.0),
      5.6,
      Paint()
        ..color = stroke.color.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.strokeWidth,
    );
    canvas.drawCircle(const Offset(9.0, 15.0), 2.2, fill);
    canvas.drawPath(
      Path()
        ..moveTo(20.4, 3.6)
        ..cubicTo(21.4, 4.6, 21.4, 5.8, 20.4, 6.8)
        ..lineTo(14.6, 12.6)
        ..lineTo(11.4, 9.4)
        ..lineTo(17.2, 3.6)
        ..cubicTo(18.2, 2.6, 19.4, 2.6, 20.4, 3.6)
        ..close(),
      stroke,
    );
  }

  // --- Chrome -----------------------------------------------------------

  void _histogram(Canvas canvas, Paint fill) {
    const heights = [5.0, 9.0, 14.0, 17.5, 15.0, 10.5, 7.0, 4.0];
    for (var i = 0; i < heights.length; i++) {
      final x = 3.0 + i * 2.4;
      canvas.drawRRect(
        RRect.fromLTRBR(
          x,
          21 - heights[i],
          x + 1.7,
          21,
          const Radius.circular(0.7),
        ),
        Paint()..color = fill.color.withValues(alpha: 0.55 + i % 2 * 0.35),
      );
    }
  }

  /// A frame split down the middle, one half filled — before and after.
  void _compare(Canvas canvas, Paint stroke, Paint fill) {
    final frame = RRect.fromLTRBR(
      2.6,
      4.6,
      21.4,
      19.4,
      const Radius.circular(2.6),
    );
    canvas.drawRRect(frame, stroke);
    canvas.save();
    canvas.clipRRect(frame);
    canvas.drawRect(
      const Rect.fromLTRB(12, 4.6, 21.4, 19.4),
      Paint()..color = fill.color.withValues(alpha: 0.85),
    );
    canvas.restore();
  }

  void _undoRedo(Canvas canvas, Paint stroke, {required bool flip}) {
    canvas.save();
    if (flip) {
      canvas.translate(24, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawPath(
      Path()
        ..moveTo(8.4, 7.2)
        ..lineTo(3.6, 11.4)
        ..lineTo(8.4, 15.6),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(3.6, 11.4)
        ..lineTo(14.2, 11.4)
        ..cubicTo(18.4, 11.4, 20.6, 13.6, 20.6, 17.0)
        ..cubicTo(20.6, 18.6, 20.0, 19.8, 19.2, 20.6),
      stroke,
    );
    canvas.restore();
  }

  void _export(Canvas canvas, Paint stroke) {
    canvas.drawPath(
      Path()
        ..moveTo(12, 15.8)
        ..lineTo(12, 3.2)
        ..moveTo(7.8, 7.4)
        ..lineTo(12, 3.2)
        ..lineTo(16.2, 7.4),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(5.2, 13.4)
        ..lineTo(5.2, 19.2)
        ..cubicTo(5.2, 20.2, 5.9, 20.8, 6.9, 20.8)
        ..lineTo(17.1, 20.8)
        ..cubicTo(18.1, 20.8, 18.8, 20.2, 18.8, 19.2)
        ..lineTo(18.8, 13.4),
      stroke,
    );
  }

  // --- Helpers ------------------------------------------------------------

  /// Marching-ants rectangle — the universal "this is a selection" cue.
  void _dashedRect(Canvas canvas, Paint stroke, Rect rect) {
    const dash = 2.6;
    const gap = 2.0;
    final paint = Paint()
      ..color = stroke.color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke.strokeWidth * 0.85
      ..strokeCap = StrokeCap.round;

    void run(Offset from, Offset to) {
      final total = (to - from).distance;
      final direction = (to - from) / total;
      var travelled = 0.0;
      while (travelled < total) {
        final end = math.min(travelled + dash, total);
        canvas.drawLine(
          from + direction * travelled,
          from + direction * end,
          paint,
        );
        travelled = end + gap;
      }
    }

    run(rect.topLeft, rect.topRight);
    run(rect.topRight, rect.bottomRight);
    run(rect.bottomRight, rect.bottomLeft);
    run(rect.bottomLeft, rect.topLeft);
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph ||
      old.color != color ||
      old.strokeScale != strokeScale;
}
