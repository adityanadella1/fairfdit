import 'package:fairedit/core/widgets/lr_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the two behaviours that make [LrSlider] the control it is —
/// relative drag and double-tap-to-origin. Both are easy to break during
/// a refactor and neither is visible in a static widget tree.
void main() {
  Future<void> pumpSlider(
    WidgetTester tester, {
    required double value,
    required ValueChanged<double> onChanged,
    double min = -100,
    double max = 100,
    double? origin,
    VoidCallback? onChangeStart,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: LrSlider(
                label: 'Exposure',
                value: value,
                min: min,
                max: max,
                origin: origin,
                onChangeStart: onChangeStart,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders its label and value', (tester) async {
    await pumpSlider(tester, value: 42, onChanged: (_) {});
    expect(find.text('Exposure'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
  });

  testWidgets('drag moves the value relatively, not to the touch point', (
    tester,
  ) async {
    final reported = <double>[];
    await pumpSlider(tester, value: 0, onChanged: reported.add);

    // Touch down well left of centre. An absolute-positioning slider
    // would snap to a large negative value on contact; this one must not
    // report anything until the finger actually travels.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(LrSlider)) - const Offset(100, 0),
    );
    await tester.pump();
    expect(reported, isEmpty);

    // The first move only crosses the touch slop, which the drag
    // recognizer consumes as the gesture's origin — the value must not
    // change yet.
    await gesture.moveBy(const Offset(kDragSlopDefault, 0));
    await tester.pump();
    expect(reported, isEmpty);

    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.up();
    // The double-tap recognizer that shares this gesture arena leaves a
    // countdown timer behind; settle so the test does not end on it.
    await tester.pumpAndSettle();

    expect(reported, isNotEmpty);
    // Moved right, so the value must have risen from 0 — and by a modest
    // amount, not jumped to the extreme.
    expect(reported.last, greaterThan(0));
    expect(reported.last, lessThan(100));
  });

  testWidgets('double tap resets to the origin', (tester) async {
    double? reset;
    var startCalls = 0;
    await pumpSlider(
      tester,
      value: 60,
      origin: 0,
      onChangeStart: () => startCalls++,
      onChanged: (v) => reset = v,
    );

    await tester.tap(find.byType(LrSlider));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(LrSlider));
    await tester.pumpAndSettle();

    expect(reset, 0);
    // The reset has to be a single undoable step, so it must open a
    // gesture the same way a drag does.
    expect(startCalls, 1);
  });

  testWidgets('double tap is a no-op when already at the origin', (
    tester,
  ) async {
    var changes = 0;
    await pumpSlider(
      tester,
      value: 0,
      origin: 0,
      onChanged: (_) => changes++,
    );

    await tester.tap(find.byType(LrSlider));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(LrSlider));
    await tester.pumpAndSettle();

    expect(changes, 0);
  });

  testWidgets('a unipolar slider defaults its origin to min', (tester) async {
    double? reset;
    await pumpSlider(
      tester,
      value: 40,
      min: 0,
      max: 100,
      onChanged: (v) => reset = v,
    );

    await tester.tap(find.byType(LrSlider));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(LrSlider));
    await tester.pumpAndSettle();

    expect(reset, 0);
  });
}
