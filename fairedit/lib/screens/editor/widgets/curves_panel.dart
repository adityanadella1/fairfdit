import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/lr_panel.dart';
import '../../../models/curves_state.dart';
import '../../../providers/edit_provider.dart';
import '../../../services/image_processing/curve_math.dart';
import 'feature_toolbar.dart';

/// The tone curve graph, with per-channel editing.
///
/// The graph is capped at 200px square rather than the panel's full width
/// so that the photo above it keeps most of the screen. A curve is read
/// by its shape, not its size — a bigger graph buys precision the finger
/// cannot use anyway.
class CurvesPanel extends StatefulWidget {
  final VoidCallback onClose;

  const CurvesPanel({super.key, required this.onClose});

  @override
  State<CurvesPanel> createState() => _CurvesPanelState();
}

class _CurvesPanelState extends State<CurvesPanel> {
  CurveChannel _channel = CurveChannel.master;
  int? _draggingIndex;

  static Color _channelColor(CurveChannel c) => switch (c) {
        CurveChannel.master => AppColors.textPrimary,
        CurveChannel.red => const Color(0xFFFF6B6B),
        CurveChannel.green => const Color(0xFF6BCB77),
        CurveChannel.blue => const Color(0xFF6BA6FF),
      };

  static String _channelLabel(CurveChannel c) => switch (c) {
        CurveChannel.master => 'RGB',
        CurveChannel.red => 'Red',
        CurveChannel.green => 'Green',
        CurveChannel.blue => 'Blue',
      };

  Offset _toCurveSpace(Offset local, Size size) {
    final x = (local.dx / size.width).clamp(0.0, 1.0);
    final y = (1 - local.dy / size.height).clamp(0.0, 1.0);
    return Offset(x, y);
  }

  Offset _toLocalSpace(CurvePoint p, Size size) =>
      Offset(p.x * size.width, (1 - p.y) * size.height);

  int? _findNearbyPointIndex(Offset local, Size size, List<CurvePoint> points) {
    const threshold = 26.0;
    double best = threshold;
    int? bestIndex;
    for (var i = 0; i < points.length; i++) {
      final d = (_toLocalSpace(points[i], size) - local).distance;
      if (d < best) {
        best = d;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final curves = provider.editState.curves;
    final activeCurve = curves.forChannel(_channel);

    return LrPanel(
      title: EditorFeature.curves.panelTitle,
      icon: EditorFeature.curves.glyph,
      onDone: widget.onClose,
      onReset: activeCurve.isIdentity
          ? null
          : () => context.read<EditProvider>().resetCurve(_channel),
      hint: 'Tap to add a point · drag to shape · hold a point to remove it',
      maxHeight: 300,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LrChipRow(
            children: [
              for (final c in CurveChannel.values)
                _ChannelChip(
                  label: _channelLabel(c),
                  color: _channelColor(c),
                  selected: c == _channel,
                  edited: !curves.forChannel(c).isIdentity,
                  onTap: () => setState(() => _channel = c),
                ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final side = math.min(constraints.maxWidth, 200.0);
              final graphSize = Size(side, side);
              return Center(
                child: SizedBox(
                  width: side,
                  height: side,
                  child: GestureDetector(
                    onPanStart: (details) {
                      final nearby = _findNearbyPointIndex(
                        details.localPosition,
                        graphSize,
                        activeCurve.points,
                      );
                      final edit = context.read<EditProvider>();
                      edit.beginAdjustmentGesture();
                      if (nearby != null) {
                        _draggingIndex = nearby;
                      } else {
                        final pos =
                            _toCurveSpace(details.localPosition, graphSize);
                        _draggingIndex = edit.addCurvePoint(
                          _channel,
                          CurvePoint(pos.dx, pos.dy),
                        );
                      }
                    },
                    onPanUpdate: (details) {
                      final index = _draggingIndex;
                      if (index == null) return;
                      final pos =
                          _toCurveSpace(details.localPosition, graphSize);
                      context.read<EditProvider>().updateCurvePoint(
                            _channel,
                            index,
                            CurvePoint(pos.dx, pos.dy),
                          );
                    },
                    onPanEnd: (_) => _draggingIndex = null,
                    onLongPressStart: (details) {
                      final nearby = _findNearbyPointIndex(
                        details.localPosition,
                        graphSize,
                        activeCurve.points,
                      );
                      if (nearby != null &&
                          nearby != 0 &&
                          nearby != activeCurve.points.length - 1) {
                        context
                            .read<EditProvider>()
                            .removeCurvePoint(_channel, nearby);
                      }
                    },
                    child: CustomPaint(
                      size: graphSize,
                      painter: _CurvePainter(
                        curves: curves,
                        activeChannel: _channel,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Channel selector. Carries its channel's own colour so the chip, the
/// curve line and the point handles all read as one thing.
class _ChannelChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool selected;
  final bool edited;
  final VoidCallback onTap;

  const _ChannelChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.edited,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppLayout.radiusSm),
        child: AnimatedContainer(
          duration: AppMotion.fast,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.16)
                : AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(AppLayout.radiusSm),
            border: Border.all(color: selected ? color : Colors.transparent),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: AppText.chip.copyWith(
                  color: selected ? color : AppColors.textSecondary,
                ),
              ),
              if (edited) ...[
                const SizedBox(width: 6),
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CurvePainter extends CustomPainter {
  final CurvesState curves;
  final CurveChannel activeChannel;

  const _CurvePainter({required this.curves, required this.activeChannel});

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(AppLayout.radiusSm),
    );
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.canvas);

    final gridPaint = Paint()
      ..color = AppColors.divider
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      final y = size.height * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // The identity diagonal — the reference every curve is read against.
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, 0),
      Paint()
        ..color = AppColors.textDisabled
        ..strokeWidth = 1,
    );

    // Inactive channels stay visible but recede, so an edit made on Red
    // is still legible while working in Blue.
    for (final c in CurveChannel.values) {
      if (c == activeChannel) continue;
      final curve = curves.forChannel(c);
      if (curve.isIdentity) continue;
      _drawCurveLine(
        canvas,
        size,
        curve.points,
        _CurvesPanelState._channelColor(c).withValues(alpha: 0.3),
        1.5,
      );
    }

    final active = curves.forChannel(activeChannel);
    final activeColor = _CurvesPanelState._channelColor(activeChannel);
    _drawCurveLine(canvas, size, active.points, activeColor, 2);
    canvas.restore();

    for (final p in active.points) {
      final pos = Offset(p.x * size.width, (1 - p.y) * size.height);
      canvas.drawCircle(pos, 5.5, Paint()..color = AppColors.canvas);
      canvas.drawCircle(
        pos,
        5.5,
        Paint()
          ..color = activeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    canvas.drawRRect(
      rrect,
      Paint()
        ..color = AppColors.divider
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _drawCurveLine(
    Canvas canvas,
    Size size,
    List<CurvePoint> points,
    Color color,
    double strokeWidth,
  ) {
    const resolution = 64;
    final values = evaluateMonotoneCubic(points, resolution);
    final path = Path();
    for (var i = 0; i < resolution; i++) {
      final x = size.width * i / (resolution - 1);
      final y = size.height * (1 - values[i]);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_CurvePainter old) =>
      old.curves != curves || old.activeChannel != activeChannel;
}
