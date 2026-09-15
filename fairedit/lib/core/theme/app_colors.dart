import 'package:flutter/material.dart';

/// FairEdit's palette.
///
/// Two rules drive every value here, and they pull against each other:
///
/// 1. **Chrome next to a photo must be neutral.** Any saturated surface
///    adjacent to the image shifts how you judge colour in it — that is
///    why every serious editor is grey, and it is not negotiable.
/// 2. **Neutral is not the same as characterless.** Everyone reaches for
///    a cold blue-grey. This ramp is warm-neutral instead: a few points
///    of red and yellow in every step. Side by side with Lightroom it
///    reads as darkroom and paper rather than cold steel, and it costs
///    nothing in colour accuracy because the hue shift stays below the
///    threshold where it biases perception.
///
/// The accent is cool mint against that warm ground — cool so it sits
/// beside skin tones without competing, mint because the blue everyone
/// else uses is Adobe's.
class AppColors {
  AppColors._();

  // --- Ground (warm neutral ramp) --------------------------------------

  /// Behind the photo. Not pure black: shadows need somewhere to fall
  /// before they hit the frame, and #000 flattens the darkest stops.
  static const canvas = Color(0xFF0B0A09);

  /// App chrome — top bar, tool rail.
  static const background = Color(0xFF141211);

  /// Editing panels.
  static const surface = Color(0xFF1C1917);

  /// Raised elements inside a panel — chips, swatches, mask rows.
  static const surfaceRaised = Color(0xFF272320);

  static const surfacePressed = Color(0xFF35302B);

  /// Hairline separators. Opaque so it renders identically on every
  /// surface above it.
  static const divider = Color(0xFF2A2623);

  // --- Text -------------------------------------------------------------

  static const textPrimary = Color(0xFFF7F4F1);
  static const textSecondary = Color(0xFFA39C95);
  static const textTertiary = Color(0xFF6E6660);
  static const textDisabled = Color(0xFF453F3A);

  // --- Accent -----------------------------------------------------------

  /// Signal mint. Reserved for state and selection — never decoration,
  /// and never in large areas next to the image.
  static const accent = Color(0xFF3ED6C0);
  static const accentPressed = Color(0xFF2FBCA8);

  /// Accent at low weight for selected fills, pre-composited against
  /// [surface] so it stays flat over scrolling content.
  static const accentSubtle = Color(0xFF17302E);

  static const danger = Color(0xFFE8615A);
  static const success = Color(0xFF3ED6C0);

  // --- Controls ---------------------------------------------------------

  /// Slider fill stays achromatic. The accent marks *state*; a coloured
  /// track sitting under your thumb while you judge white balance is
  /// exactly the bias rule 1 exists to prevent.
  static const sliderActive = Color(0xFFEDE9E5);
  static const sliderInactive = Color(0xFF38322D);
  static const sliderThumb = Color(0xFFFFFFFF);
  static const sliderOrigin = Color(0xFF5E564F);

  static const scrim = Color(0xAA0B0A09);
  static const gridLine = Color(0x59FFFFFF);
}

/// Colour ramps painted into slider tracks.
///
/// Only for parameters whose axis genuinely *is* a colour. A ramp on
/// Exposure would be decoration; a ramp on Temperature is a legend — it
/// tells you which way is warmer without you reading the number.
class AppRamps {
  AppRamps._();

  /// Cool to warm, matching the white-balance convention: drag right and
  /// the photo goes amber, exactly as the track does.
  static const temperature = [
    Color(0xFF3F7FD0),
    Color(0xFF9A938C),
    Color(0xFFF0A63A),
  ];

  /// The opposing axis of white balance.
  static const tint = [
    Color(0xFF52B072),
    Color(0xFF9A938C),
    Color(0xFFCE5CA8),
  ];

  /// Grey to full colour — the direction saturation and vibrance move.
  static const saturation = [
    Color(0xFF7A736D),
    Color(0xFF2AA9A0),
    Color(0xFF3ED6C0),
  ];

  /// Black to white, for controls that select over a luminance range.
  static const luminance = [Color(0xFF0B0A09), Color(0xFFF7F4F1)];
}
