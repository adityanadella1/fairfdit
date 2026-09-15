import 'package:fairedit/core/widgets/lr_range_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two-handle band selector. Its interesting behaviour is all in
/// gesture handling — which handle a touch grabs, and the invariants that
/// keep the band valid — none of which is visible in a static tree.
void main() {
  const totalWidth = 400.0;
  // The track spans the full row, so a fraction along the row is a
  // fraction along the track.
  const trackWidth = totalWidth;

  Future<void> pump(
    WidgetTester tester, {
    required double low,
    required double high,
    required void Function(double, double) onChanged,
    VoidCallback? onChangeStart,
    double defaultLow = 0.0,
    double defaultHigh = 0.45,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: totalWidth,
              child: LrRangeSlider(
                label: 'Range',
                low: low,
                high: high,
                trackGradient: const [Colors.black, Colors.white],
                defaultLow: defaultLow,
                defaultHigh: defaultHigh,
                onChangeStart: onChangeStart,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Starts a drag at [fraction] along the track and moves by [dx].
  Future<void> dragFrom(
    WidgetTester tester,
    double fraction,
    double dx,
  ) async {
    final topLeft = tester.getTopLeft(find.byType(LrRangeSlider));
    final size = tester.getSize(find.byType(LrRangeSlider));
    final start = Offset(
      topLeft.dx + trackWidth * fraction,
      // The track is the lower of the two rows.
      topLeft.dy + size.height * 0.75,
    );

    final gesture = await tester.startGesture(start);
    // First move only crosses the touch slop; the second produces the
    // actual delta.
    await gesture.moveBy(const Offset(kDragSlopDefault, 0));
    await tester.pump();
    await gesture.moveBy(Offset(dx, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('renders the band as a range readout', (tester) async {
    await pump(tester, low: 0.2, high: 0.8, onChanged: (_, __) {});
    expect(find.text('Range'), findsOneWidget);
    expect(find.text('20–80'), findsOneWidget);
  });

  testWidgets('a touch near the low handle drags the low handle', (
    tester,
  ) async {
    double? low, high;
    await pump(
      tester,
      low: 0.2,
      high: 0.8,
      onChanged: (l, h) {
        low = l;
        high = h;
      },
    );

    await dragFrom(tester, 0.2, 30);

    expect(low, isNotNull);
    expect(low, greaterThan(0.2), reason: 'low handle should have moved right');
    expect(high, 0.8, reason: 'high handle must not move');
  });

  testWidgets('a touch near the high handle drags the high handle', (
    tester,
  ) async {
    double? low, high;
    await pump(
      tester,
      low: 0.2,
      high: 0.8,
      onChanged: (l, h) {
        low = l;
        high = h;
      },
    );

    await dragFrom(tester, 0.8, -30);

    expect(high, isNotNull);
    expect(high, lessThan(0.8));
    expect(low, 0.2, reason: 'low handle must not move');
  });

  testWidgets('handles cannot cross, and keep a usable gap', (tester) async {
    double? low, high;
    await pump(
      tester,
      low: 0.4,
      high: 0.5,
      onChanged: (l, h) {
        low = l;
        high = h;
      },
    );

    // Shove the low handle far past the high one.
    await dragFrom(tester, 0.4, trackWidth);

    expect(low! < high!, isTrue, reason: 'handles crossed');
    expect(
      high! - low!,
      greaterThanOrEqualTo(LrRangeSlider.minGap - 0.0001),
      reason: 'handles collapsed into one unhittable target',
    );
  });

  testWidgets('values stay within 0..1', (tester) async {
    double? low, high;
    await pump(
      tester,
      low: 0.1,
      high: 0.9,
      onChanged: (l, h) {
        low = l;
        high = h;
      },
    );

    await dragFrom(tester, 0.1, -trackWidth * 2);
    expect(low, greaterThanOrEqualTo(0.0));

    await dragFrom(tester, 0.9, trackWidth * 2);
    expect(high, lessThanOrEqualTo(1.0));
  });

  testWidgets('double tap restores both defaults as one undo step', (
    tester,
  ) async {
    double? low, high;
    var startCalls = 0;
    await pump(
      tester,
      low: 0.3,
      high: 0.7,
      onChangeStart: () => startCalls++,
      onChanged: (l, h) {
        low = l;
        high = h;
      },
    );

    await tester.tap(find.byType(LrRangeSlider));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(LrRangeSlider));
    await tester.pumpAndSettle();

    expect(low, 0.0);
    expect(high, 0.45);
    expect(startCalls, 1, reason: 'reset must be a single undoable step');
  });

  testWidgets('double tap is a no-op when already at the defaults', (
    tester,
  ) async {
    var changes = 0;
    await pump(
      tester,
      low: 0.0,
      high: 0.45,
      onChanged: (_, __) => changes++,
    );

    await tester.tap(find.byType(LrRangeSlider));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(LrRangeSlider));
    await tester.pumpAndSettle();

    expect(changes, 0);
  });
}
