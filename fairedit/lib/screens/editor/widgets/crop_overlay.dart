import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/edit_provider.dart';

enum _Handle { topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right, move }

/// Preset pixel aspect ratios by label — shared with CropBar's buttons.
/// 'Free' and 'Original' aren't here: Free has no lock, Original locks to
/// the frame's own shape (fraction ratio 1.0), computed specially below.
const Map<String, double> cropAspectPixelRatios = {
  '1:1': 1.0,
  '4:3': 4 / 3,
  '3:4': 3 / 4,
  '16:9': 16 / 9,
  '9:16': 9 / 16,
};

/// The interactive crop rectangle: 8 draggable handles (corners always,
/// edge midpoints only when no aspect ratio is locked), a dimmed area
/// outside the rect, and rule-of-thirds guide lines inside it. Meant to
/// be passed as EditorImageStack's `overlay` while showing the full
/// (uncropped) straightened/rotated frame underneath.
class CropInteractionLayer extends StatefulWidget {
  const CropInteractionLayer({super.key});

  @override
  State<CropInteractionLayer> createState() => _CropInteractionLayerState();
}

class _CropInteractionLayerState extends State<CropInteractionLayer> {
  static const double _minSize = 0.08;

  _Handle? _activeHandle;
  Offset? _dragStartLocal;
  ({double left, double top, double right, double bottom})? _dragStartRect;

  double? _lockedFractionRatio(EditProvider provider, String? label) {
    if (label == null) return null;
    final img = provider.image;
    if (img == null) return null;
    final crop = provider.editState.crop;
    final swapped = crop.rotationSteps == 1 || crop.rotationSteps == 3;
    final frameRatio = swapped ? img.height / img.width : img.width / img.height;
    if (label == 'Original') return 1.0;
    final target = cropAspectPixelRatios[label];
    if (target == null) return null;
    return target / frameRatio;
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<EditProvider>();
    final crop = provider.editState.crop;
    final showEdgeHandles = crop.aspectPresetLabel == null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        Offset toPixel(double x, double y) => Offset(x * size.width, y * size.height);
        final rect = Rect.fromPoints(
          toPixel(crop.left, crop.top),
          toPixel(crop.right, crop.bottom),
        );

        final handlePositions = <_Handle, Offset>{
          _Handle.topLeft: rect.topLeft,
          _Handle.topRight: rect.topRight,
          _Handle.bottomLeft: rect.bottomLeft,
          _Handle.bottomRight: rect.bottomRight,
          if (showEdgeHandles) _Handle.top: Offset(rect.center.dx, rect.top),
          if (showEdgeHandles) _Handle.bottom: Offset(rect.center.dx, rect.bottom),
          if (showEdgeHandles) _Handle.left: Offset(rect.left, rect.center.dy),
          if (showEdgeHandles) _Handle.right: Offset(rect.right, rect.center.dy),
        };

        _Handle? hitTest(Offset local) {
          const threshold = 30.0;
          _Handle? best;
          var bestDist = threshold;
          for (final entry in handlePositions.entries) {
            final d = (entry.value - local).distance;
            if (d < bestDist) {
              bestDist = d;
              best = entry.key;
            }
          }
          if (best != null) return best;
          if (rect.contains(local)) return _Handle.move;
          return null;
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            final handle = hitTest(d.localPosition);
            if (handle == null) return;
            _activeHandle = handle;
            _dragStartLocal = d.localPosition;
            _dragStartRect = (left: crop.left, top: crop.top, right: crop.right, bottom: crop.bottom);
            context.read<EditProvider>().beginAdjustmentGesture();
          },
          onPanUpdate: (d) {
            final handle = _activeHandle;
            final start = _dragStartLocal;
            final startRect = _dragStartRect;
            if (handle == null || start == null || startRect == null) return;
            final dxN = (d.localPosition.dx - start.dx) / size.width;
            final dyN = (d.localPosition.dy - start.dy) / size.height;
            _applyDrag(
              provider: context.read<EditProvider>(),
              handle: handle,
              start: startRect,
              dxN: dxN,
              dyN: dyN,
              lockedRatio: _lockedFractionRatio(provider, crop.aspectPresetLabel),
            );
          },
          onPanEnd: (_) {
            _activeHandle = null;
            _dragStartLocal = null;
            _dragStartRect = null;
          },
          child: CustomPaint(
            size: size,
            painter: _CropPainter(rect: rect, fullSize: size, showEdgeHandles: showEdgeHandles),
          ),
        );
      },
    );
  }

  void _applyDrag({
    required EditProvider provider,
    required _Handle handle,
    required ({double left, double top, double right, double bottom}) start,
    required double dxN,
    required double dyN,
    required double? lockedRatio,
  }) {
    switch (handle) {
      case _Handle.move:
        final w = start.right - start.left;
        final h = start.bottom - start.top;
        final left = (start.left + dxN).clamp(0.0, 1.0 - w);
        final top = (start.top + dyN).clamp(0.0, 1.0 - h);
        provider.updateCropRect(left: left, top: top, right: left + w, bottom: top + h);
        return;
      case _Handle.left:
        provider.updateCropRect(left: (start.left + dxN).clamp(0.0, start.right - _minSize));
        return;
      case _Handle.right:
        provider.updateCropRect(right: (start.right + dxN).clamp(start.left + _minSize, 1.0));
        return;
      case _Handle.top:
        provider.updateCropRect(top: (start.top + dyN).clamp(0.0, start.bottom - _minSize));
        return;
      case _Handle.bottom:
        provider.updateCropRect(bottom: (start.bottom + dyN).clamp(start.top + _minSize, 1.0));
        return;
      case _Handle.topLeft:
      case _Handle.topRight:
      case _Handle.bottomLeft:
      case _Handle.bottomRight:
        _applyCornerDrag(provider, start, handle, dxN, dyN, lockedRatio);
        return;
    }
  }

  void _applyCornerDrag(
    EditProvider provider,
    ({double left, double top, double right, double bottom}) start,
    _Handle handle,
    double dxN,
    double dyN,
    double? lockedRatio,
  ) {
    late double ax, ay, px, py;
    switch (handle) {
      case _Handle.topLeft:
        ax = start.right;
        ay = start.bottom;
        px = start.left + dxN;
        py = start.top + dyN;
        break;
      case _Handle.topRight:
        ax = start.left;
        ay = start.bottom;
        px = start.right + dxN;
        py = start.top + dyN;
        break;
      case _Handle.bottomLeft:
        ax = start.right;
        ay = start.top;
        px = start.left + dxN;
        py = start.bottom + dyN;
        break;
      case _Handle.bottomRight:
        ax = start.left;
        ay = start.top;
        px = start.right + dxN;
        py = start.bottom + dyN;
        break;
      default:
        return;
    }

    if (lockedRatio == null) {
      final left = math.min(ax, px).clamp(0.0, 1.0);
      final right = math.max(ax, px).clamp(0.0, 1.0);
      final top = math.min(ay, py).clamp(0.0, 1.0);
      final bottom = math.max(ay, py).clamp(0.0, 1.0);
      if (right - left < _minSize || bottom - top < _minSize) return;
      provider.updateCropRect(left: left, top: top, right: right, bottom: bottom);
      return;
    }

    final dx = px - ax;
    final dy = py - ay;
    final wFromDx = dx.abs();
    final hFromDx = wFromDx / lockedRatio;
    final hFromDy = dy.abs();
    final wFromDy = hFromDy * lockedRatio;
    double w, h;
    if (wFromDx >= wFromDy) {
      w = wFromDx;
      h = hFromDx;
    } else {
      w = wFromDy;
      h = hFromDy;
    }

    final sx = dx.isNegative ? -1.0 : 1.0;
    final sy = dy.isNegative ? -1.0 : 1.0;
    final newX2 = (ax + sx * w).clamp(0.0, 1.0);
    final newY2 = (ay + sy * h).clamp(0.0, 1.0);
    final left = math.min(ax, newX2);
    final right = math.max(ax, newX2);
    final top = math.min(ay, newY2);
    final bottom = math.max(ay, newY2);
    if (right - left < _minSize || bottom - top < _minSize) return;
    provider.updateCropRect(left: left, top: top, right: right, bottom: bottom);
  }
}

class _CropPainter extends CustomPainter {
  final Rect rect;
  final Size fullSize;
  final bool showEdgeHandles;

  _CropPainter({required this.rect, required this.fullSize, required this.showEdgeHandles});

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    // Dim everything outside the rect via 4 strips (avoids needing a
    // punch-hole path, simple and cheap).
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), dim);
    canvas.drawRect(Rect.fromLTRB(0, rect.bottom, size.width, size.height), dim);
    canvas.drawRect(Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), dim);
    canvas.drawRect(Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom), dim);

    // Rule-of-thirds guide lines.
    final guide = Paint()
      ..color = Colors.white54
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = rect.left + rect.width * i / 3;
      final y = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), guide);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), guide);
    }

    // Rect border.
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Corner handles — small thick L-shapes, a common crop-tool convention.
    const armLength = 18.0;
    const armWidth = 3.5;
    final handlePaint = Paint()
      ..color = Colors.white
      ..strokeWidth = armWidth
      ..strokeCap = StrokeCap.round;

    void corner(Offset p, double dx, double dy) {
      canvas.drawLine(p, p + Offset(dx * armLength, 0), handlePaint);
      canvas.drawLine(p, p + Offset(0, dy * armLength), handlePaint);
    }

    corner(rect.topLeft, 1, 1);
    corner(rect.topRight, -1, 1);
    corner(rect.bottomLeft, 1, -1);
    corner(rect.bottomRight, -1, -1);

    if (showEdgeHandles) {
      const edgeHandleLength = 16.0;
      void edge(Offset center, bool horizontal) {
        const half = edgeHandleLength / 2;
        final p1 = horizontal
            ? center - const Offset(half, 0)
            : center - const Offset(0, half);
        final p2 = horizontal
            ? center + const Offset(half, 0)
            : center + const Offset(0, half);
        canvas.drawLine(p1, p2, handlePaint);
      }

      edge(Offset(rect.center.dx, rect.top), true);
      edge(Offset(rect.center.dx, rect.bottom), true);
      edge(Offset(rect.left, rect.center.dy), false);
      edge(Offset(rect.right, rect.center.dy), false);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) {
    return oldDelegate.rect != rect || oldDelegate.showEdgeHandles != showEdgeHandles;
  }
}
