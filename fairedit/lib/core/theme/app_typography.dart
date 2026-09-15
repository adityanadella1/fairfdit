import 'package:flutter/material.dart';

import 'app_colors.dart';

/// The editor's type scale.
///
/// No custom font: a binary asset buys less here than discipline does.
/// The character comes from *contrast* instead — heavy, tightly-tracked
/// display type against small, widely-tracked instrument labels. That
/// gap is what makes a panel read as a machined tool rather than a
/// settings screen, and it costs nothing to ship.
class AppText {
  AppText._();

  /// Screen / project title in the top bar.
  static const title = TextStyle(
    fontSize: 15,
    height: 1.15,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    // Negative tracking at display weight: tight is what reads as
    // editorial rather than as a system dialog.
    letterSpacing: -0.3,
  );

  /// Panel header ("Light", "Color", "Masking").
  static const panelTitle = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w800,
    color: AppColors.textPrimary,
    // The opposite extreme from [title] — small, heavy, widely tracked.
    // Instrument-panel lettering.
    letterSpacing: 1.6,
  );

  /// Group heading inside a scrolling panel.
  static const sectionLabel = TextStyle(
    fontSize: 10,
    height: 1.2,
    fontWeight: FontWeight.w700,
    color: AppColors.textTertiary,
    letterSpacing: 1.8,
  );

  /// Slider / control label.
  static const control = TextStyle(
    fontSize: 13,
    height: 1.2,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
  );

  /// Numeric readout next to a slider. Tabular so digits don't jitter as
  /// the value changes during a drag.
  static const value = TextStyle(
    fontSize: 13,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Tool-rail item caption.
  static const caption = TextStyle(
    fontSize: 10,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: AppColors.textSecondary,
    letterSpacing: 0.4,
  );

  /// Inline hint / helper text under a control.
  static const hint = TextStyle(
    fontSize: 11,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: AppColors.textTertiary,
  );

  /// Chip / segmented-control label.
  static const chip = TextStyle(
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: AppColors.textSecondary,
  );
}

/// Shared timings. Panels and selection states animate on the same
/// curve so the whole editor feels like one mechanism.
class AppMotion {
  AppMotion._();

  static const fast = Duration(milliseconds: 90);
  static const medium = Duration(milliseconds: 160);
  static const slow = Duration(milliseconds: 240);

  /// Fast out of the gate, settling at the end. An instrument should
  /// answer the finger immediately; the previous easeOutCubic at 220ms
  /// spent its first frames barely moving, which reads as lag even though
  /// the total duration is short.
  static const emphasized = Cubic(0.16, 1.0, 0.3, 1.0);
  static const standard = Curves.easeOutQuart;
}

/// Layout constants that several widgets need to agree on.
class AppLayout {
  AppLayout._();

  /// Height of the bottom tool rail.
  static const toolRailHeight = 64.0;

  /// Standard horizontal gutter inside panels.
  static const gutter = 16.0;

  static const radiusSm = 6.0;
  static const radiusMd = 10.0;
  static const radiusLg = 16.0;
}
