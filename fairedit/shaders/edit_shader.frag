#include <flutter/runtime_effect.glsl>

// Canvas size the shader is being drawn into (the OUTPUT frame — after
// crop, if any). Also used to derive aspect ratio for Blur/Vignette/
// Grain, so their falloffs stay round/consistent regardless of the
// photo's own aspect ratio.
uniform vec2 uSize;
// The RAW/original image's own aspect ratio (width/height) — constant
// per photo regardless of crop state. Needed for Straighten's
// auto-scale-to-fill math, which operates on the raw frame specifically.
uniform float uImageAspect;

// Adjustments — all normalized to roughly -1.0..1.0 by EditState.toUniformList().
// The order here MUST match EditState.toUniformList() exactly.
uniform float uExposure;
uniform float uContrast;
uniform float uHighlights;
uniform float uShadows;
uniform float uWhites;
uniform float uBlacks;
uniform float uBrightness;
uniform float uSaturation;
uniform float uVibrance;
uniform float uWarmth;
uniform float uTint;

// Color Grading — three tonal ranges (hue 0..1 turns, saturation/luminance
// 0..1) plus a global blend-width control.
uniform float uGradeShadowHue;
uniform float uGradeShadowSat;
uniform float uGradeShadowLum;
uniform float uGradeMidHue;
uniform float uGradeMidSat;
uniform float uGradeMidLum;
uniform float uGradeHighHue;
uniform float uGradeHighSat;
uniform float uGradeHighLum;
uniform float uGradeBlending;

// Blur — simulated lens blur. Focus point in 0..1 OUTPUT-frame space,
// amount and sharp-zone size both 0..1. uBlurBokehShape is a plain float
// encoding of BokehShape's index (0=circular,1=soapBubble,2=polygonal,
// 3=ring,4=oval).
uniform float uBlurFocusX;
uniform float uBlurFocusY;
uniform float uBlurAmount;
uniform float uBlurSize;
uniform float uBlurBokehShape;
uniform float uBlurCatEye;
uniform float uBlurBoost;
// 1.0 once "Select Subject" has been run and is active — switches the
// blur falloff from point/distance-based to sampling uSubjectMask.
uniform float uUseSubjectMask;

// Effects — Sharpen/Clarity/Dehaze apply early (raw-domain, before the
// rest of the tone/color pipeline); Vignette/Grain apply last, as
// finishing touches on the fully graded image.
uniform float uEffectSharpen;
uniform float uEffectClarity;
uniform float uEffectDehaze;
uniform float uEffectVignetteAmount;
uniform float uEffectVignetteSize;
uniform float uEffectGrainAmount;
uniform float uEffectGrainSize;

// Crop / Straighten / Rotate / Flip — the only feature so far that
// changes the image's own dimensions rather than just its colors. See
// mapOutputToRaw() for how these combine. left/top/right/bottom are
// fractions of the frame AFTER straighten+rotationSteps+flip.
uniform float uCropLeft;
uniform float uCropTop;
uniform float uCropRight;
uniform float uCropBottom;
uniform float uCropStraightenAngle; // radians
uniform float uCropRotationSteps; // 0,1,2,3 = 0/90/180/270 clockwise
uniform float uCropFlipH;
uniform float uCropFlipV;

// Masking — up to 6 local-adjustment masks, each a fixed 11-float slot
// regardless of type (unused slots have type=0="off"). Shape params
// (P0..P4) mean different things per type — see applyMaskSlot() below.
//
// The count is mirrored by MaskingState.maxSlots in Dart; the two must
// stay in step or EditState.toUniformList() writes past the end of the
// uniform block.
// Slot 0
uniform float uMask0Type;
uniform float uMask0Invert;
uniform float uMask0P0;
uniform float uMask0P1;
uniform float uMask0P2;
uniform float uMask0P3;
uniform float uMask0P4;
uniform float uMask0Exposure;
uniform float uMask0Contrast;
uniform float uMask0Saturation;
uniform float uMask0Warmth;
// Slot 1
uniform float uMask1Type;
uniform float uMask1Invert;
uniform float uMask1P0;
uniform float uMask1P1;
uniform float uMask1P2;
uniform float uMask1P3;
uniform float uMask1P4;
uniform float uMask1Exposure;
uniform float uMask1Contrast;
uniform float uMask1Saturation;
uniform float uMask1Warmth;
// Slot 2
uniform float uMask2Type;
uniform float uMask2Invert;
uniform float uMask2P0;
uniform float uMask2P1;
uniform float uMask2P2;
uniform float uMask2P3;
uniform float uMask2P4;
uniform float uMask2Exposure;
uniform float uMask2Contrast;
uniform float uMask2Saturation;
uniform float uMask2Warmth;
// Slot 3
uniform float uMask3Type;
uniform float uMask3Invert;
uniform float uMask3P0;
uniform float uMask3P1;
uniform float uMask3P2;
uniform float uMask3P3;
uniform float uMask3P4;
uniform float uMask3Exposure;
uniform float uMask3Contrast;
uniform float uMask3Saturation;
uniform float uMask3Warmth;
// Slot 4
uniform float uMask4Type;
uniform float uMask4Invert;
uniform float uMask4P0;
uniform float uMask4P1;
uniform float uMask4P2;
uniform float uMask4P3;
uniform float uMask4P4;
uniform float uMask4Exposure;
uniform float uMask4Contrast;
uniform float uMask4Saturation;
uniform float uMask4Warmth;
// Slot 5
uniform float uMask5Type;
uniform float uMask5Invert;
uniform float uMask5P0;
uniform float uMask5P1;
uniform float uMask5P2;
uniform float uMask5P3;
uniform float uMask5P4;
uniform float uMask5Exposure;
uniform float uMask5Contrast;
uniform float uMask5Saturation;
uniform float uMask5Warmth;
uniform sampler2D uTexture;
// 256x1 tone-curve lookup table — see curve_math.dart / buildCurveLutBytes.
// Master + per-channel curves are pre-composed into this one texture, so
// this shader only ever needs one read per channel.
uniform sampler2D uCurveLUT;
// On-device subject-segmentation mask (red channel = subject confidence
// 0..1) from google_mlkit_selfie_segmentation, same width/height as the
// photo. Only meaningful when uUseSubjectMask > 0.5 — otherwise a tiny
// placeholder texture is bound here and never sampled.
uniform sampler2D uSubjectMask;
// Heal — uHealMask (red channel = healed strength 0..1, painted by the
// user) and uHealedTexture (the diffusion-inpainted fill, see
// heal_diffusion.frag / HealEngine). Both are harmless all-zero
// placeholders before anything has been healed.
uniform sampler2D uHealMask;
uniform sampler2D uHealedTexture;
// One coverage texture per masking slot — meaningful when that slot's
// type is texture-backed (Brush or AI, both encoded as 3); harmless
// all-zero placeholders otherwise.
uniform sampler2D uMask0Brush;
uniform sampler2D uMask1Brush;
uniform sampler2D uMask2Brush;
uniform sampler2D uMask3Brush;
uniform sampler2D uMask4Brush;
uniform sampler2D uMask5Brush;

out vec4 fragColor;

const int BLUR_SAMPLES = 12;
const float GOLDEN_ANGLE = 2.399963;
const float PI = 3.14159265;

float luma(vec3 c) {
  return dot(c, vec3(0.299, 0.587, 0.114));
}

// Standard hue (0..1 turns) to RGB, full saturation/value — used to turn a
// color-wheel pick into an actual tint color for grading.
vec3 hueToRgb(float h) {
  vec3 rgb = clamp(abs(mod(h * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
  return rgb;
}

// Undoes a 90-degree-step rotation: given a coordinate in the ROTATED
// frame, returns the corresponding coordinate in the PRE-rotation frame.
// steps counts how many 90-degree CLOCKWISE turns were applied going
// forward (raw -> rotated).
vec2 undoRotationSteps(vec2 uv, float steps) {
  if (steps < 0.5) {
    return uv;
  } else if (steps < 1.5) {
    return vec2(uv.y, 1.0 - uv.x);
  } else if (steps < 2.5) {
    return vec2(1.0 - uv.x, 1.0 - uv.y);
  } else {
    return vec2(1.0 - uv.y, uv.x);
  }
}

// Undoes Straighten's small-angle rotation. Straighten rotates the raw
// image by angleRad (positive = clockwise) around its center, then
// auto-scales up just enough that the output frame never shows empty
// corners — this computes that scale from the raw image's own aspect
// ratio and finds the raw-space coordinate for a given straightened-
// space coordinate.
vec2 undoStraighten(vec2 uv, float angleRad, float imageAspect) {
  if (abs(angleRad) < 0.0005) {
    return uv;
  }
  float ca = abs(cos(angleRad));
  float sa = abs(sin(angleRad));
  float term1 = ca + sa / imageAspect;
  float term2 = imageAspect * sa + ca;
  float scale = max(term1, term2);

  // UV space is not isotropic: one unit of x spans imageAspect times
  // more pixels than one unit of y. Rotating directly in it SHEARS the
  // image instead of rotating it, which is why straighten used to smear
  // the frame. Scale x into a square space, rotate there, scale back.
  vec2 centered = (uv - 0.5) / scale;
  centered.x *= imageAspect;

  float cosA = cos(-angleRad);
  float sinA = sin(-angleRad);
  vec2 rotated = vec2(
    centered.x * cosA - centered.y * sinA,
    centered.x * sinA + centered.y * cosA
  );

  rotated.x /= imageAspect;
  return rotated + 0.5;
}

// The full backward chain: given a coordinate in the FINAL output frame
// (post crop), finds the corresponding coordinate in the raw source
// image, undoing crop -> flip -> rotationSteps -> straighten in that
// order (the exact reverse of how they're applied going forward).
vec2 mapOutputToRaw(vec2 outputUV) {
  vec2 uv = mix(vec2(uCropLeft, uCropTop), vec2(uCropRight, uCropBottom), outputUV);
  if (uCropFlipH > 0.5) uv.x = 1.0 - uv.x;
  if (uCropFlipV > 0.5) uv.y = 1.0 - uv.y;
  uv = undoRotationSteps(uv, uCropRotationSteps);
  uv = undoStraighten(uv, uCropStraightenAngle, uImageAspect);
  return uv;
}

// A cheap single-pass "bokeh" approximation: samples in a golden-angle
// spiral disc around uv and averages them, with a few stylistic variants
// layered on (shape, cat eye edge-stretch, highlight boost). radius is in
// the same aspect-corrected physical-normalized space as the focus mask
// below, so offsets get divided by aspectScale to land back in UV space.
vec3 bokehBlur(vec2 uv, float radius, vec2 aspectScale, float shape, float catEye, float boost) {
  vec3 sum = texture(uTexture, uv).rgb;
  float totalWeight = 1.0;

  vec2 fromCenter = uv - vec2(0.5);
  float edgeDist = length(fromCenter * aspectScale);
  vec2 stretchDir = edgeDist > 0.001 ? normalize(fromCenter) : vec2(1.0, 0.0);
  float stretchAmount = 1.0 + catEye * edgeDist * 1.5;

  bool isSoapBubble = shape > 0.5 && shape < 1.5;
  bool isPolygonal = shape > 1.5 && shape < 2.5;
  bool isRing = shape > 2.5 && shape < 3.5;
  bool isOval = shape > 3.5;

  for (int i = 0; i < BLUR_SAMPLES; i++) {
    float a = float(i) * GOLDEN_ANGLE;
    float t = float(i) / float(BLUR_SAMPLES);
    float r = sqrt(t) * radius;

    if (isRing) {
      r = mix(radius * 0.55, radius, t);
    }

    if (isPolygonal) {
      float sides = 6.0;
      float angle = mod(a, 2.0 * PI / sides) - (PI / sides);
      r *= cos(PI / sides) / cos(angle);
    }

    vec2 offset = (vec2(cos(a), sin(a)) * r) / aspectScale;

    if (isOval) {
      offset.x *= 1.6;
    }

    if (catEye > 0.001) {
      float alongStretch = max(dot(normalize(offset + 1e-5), stretchDir), 0.0);
      offset *= mix(1.0, stretchAmount, alongStretch);
    }

    vec3 sampleColor = texture(uTexture, uv + offset).rgb;

    float w = 1.0;
    if (isSoapBubble) {
      w *= mix(0.4, 1.6, t);
    }
    w *= 1.0 + boost * smoothstep(0.55, 1.0, luma(sampleColor)) * 2.5;

    sum += sampleColor * w;
    totalWeight += w;
  }

  return sum / totalWeight;
}

// Computes one masking slot's coverage (0..1) and blends its focused
// local adjustments in proportionally. Called once per slot (3x) from
// main(), since GLSL uniforms here are individually-named rather than a
// true array — type<0.5 means the slot is unused ("off") and passes
// through unchanged.
vec3 applyMaskSlot(
  vec3 c, vec2 outputUV, vec2 uv,
  float type, float invert, float p0, float p1, float p2, float p3, float p4,
  float exposure, float contrast, float saturation, float warmth,
  float brushCoverage
) {
  if (type < 0.5) return c;

  float coverage;
  if (type < 1.5) {
    // Linear gradient: p0,p1 = start (no effect), p2,p3 = end (full
    // effect), smooth transition between. Computed in outputUV space —
    // a gradient is about the current framing, not raw pixel content.
    vec2 startPt = vec2(p0, p1);
    vec2 endPt = vec2(p2, p3);
    vec2 dir = endPt - startPt;
    float len = length(dir);
    vec2 dirNorm = len > 0.0001 ? dir / len : vec2(1.0, 0.0);
    float t = dot(outputUV - startPt, dirNorm) / max(len, 0.0001);
    coverage = clamp(t, 0.0, 1.0);
  } else if (type < 2.5) {
    // Radial gradient: p0,p1 = center, p2,p3 = radiusX/radiusY, p4 =
    // feather. Full effect inside the ellipse, feathered falloff at the
    // edge. Also outputUV-based, same reasoning as linear.
    vec2 delta = outputUV - vec2(p0, p1);
    vec2 normalized = vec2(delta.x / max(p2, 0.0001), delta.y / max(p3, 0.0001));
    float dist = length(normalized);
    float featherAmt = max(p4, 0.001);
    coverage = 1.0 - smoothstep(1.0 - featherAmt, 1.0, dist);
  } else if (type < 3.5) {
    // Texture-backed (Brush or AI): already sampled by the caller at
    // raw-mapped uv, so it stays content-locked through crop/rotate/flip
    // the same way Heal's mask does.
    coverage = brushCoverage;
  } else if (type < 4.5) {
    // Luminance range: p0 = low edge, p1 = high edge, p2 = smoothness.
    //
    // Evaluated on `c`, the colour as it stands at this point in the
    // pipeline — after global tone and grading, before this mask. That
    // is what makes it useful: "darken whatever is still bright after my
    // exposure edit" is the actual intent, and sampling the raw pixel
    // would answer a different question.
    float l = luma(c);
    // Smoothness spreads the falloff either side of each edge. Without
    // a floor the band becomes a hard threshold and the selection
    // aliases badly along gradients like a sky.
    float soft = max(p2, 0.004) * 0.5;
    coverage = smoothstep(p0 - soft, p0 + soft, l)
             * (1.0 - smoothstep(p1 - soft, p1 + soft, l));
  } else {
    // Colour range: p0,p1,p2 = sampled target RGB, p3 = tolerance.
    //
    // Distance is measured mostly in chroma, with luminance contributing
    // only a third as much. Straight RGB distance would select "this
    // red, at this brightness" — so a red shirt would be picked in the
    // light and dropped in shadow, which is never what someone sampling
    // a colour means.
    vec3 target = vec3(p0, p1, p2);
    float cLuma = luma(c);
    float tLuma = luma(target);
    float chromaDist = length((c - cLuma) - (target - tLuma));
    float lumaDist = abs(cLuma - tLuma);
    float d = chromaDist + lumaDist * 0.35;

    float tolerance = max(p3, 0.004);
    coverage = 1.0 - smoothstep(tolerance * 0.5, tolerance, d);
  }

  if (invert > 0.5) coverage = 1.0 - coverage;
  if (coverage <= 0.001) return c;

  vec3 adjusted = c;
  adjusted *= pow(2.0, exposure * 2.0);
  adjusted = (adjusted - 0.5) * (1.0 + contrast) + 0.5;
  float maskGray = luma(adjusted);
  adjusted = mix(vec3(maskGray), adjusted, 1.0 + saturation);
  adjusted.r += warmth * 0.18;
  adjusted.b -= warmth * 0.18;
  adjusted = clamp(adjusted, 0.0, 1.0);

  return mix(c, adjusted, coverage);
}

void main() {
  // outputUV is the FINAL frame's own space (post-crop) — used for every
  // effect that should relate to what's currently framed (Vignette,
  // Grain, Blur's focus point). uv is the corresponding position back in
  // the raw source image — used for every actual texture sample.
  vec2 outputUV = FlutterFragCoord().xy / uSize;
  vec2 uv = mapOutputToRaw(outputUV);

  vec4 src = texture(uTexture, uv);
  vec3 rawSharp = src.rgb;

  // Heal — applied first, as a base-layer fix: blends in the diffusion-
  // inpainted result wherever the user painted, leaving everything else
  // untouched (an all-zero mask before anything's been healed makes this
  // a no-op).
  float healAmount = texture(uHealMask, uv).r;
  if (healAmount > 0.001) {
    vec3 healedColor = texture(uHealedTexture, uv).rgb;
    rawSharp = mix(rawSharp, healedColor, healAmount);
  }

  // aspectScale lets frame-relative effects stay physically circular
  // regardless of the CURRENT (post-crop) frame's aspect ratio.
  float minDim = min(uSize.x, uSize.y);
  vec2 aspectScale = uSize / minDim;

  vec3 c = rawSharp;
  if (uBlurAmount > 0.001) {
    float blurMask;
    if (uUseSubjectMask > 0.5) {
      // Subject mode: sharp where the detected subject is, blurred
      // everywhere else. The mask was computed on the raw image, so it
      // samples with the raw-mapped uv, not outputUV. A mild smoothstep
      // tightens ML Kit's naturally soft confidence values into a more
      // decisive edge.
      float subjectConfidence = texture(uSubjectMask, uv).r;
      blurMask = 1.0 - smoothstep(0.35, 0.65, subjectConfidence);
    } else {
      // Point mode: sharp near the focus point the user dragged on the
      // CURRENT (possibly cropped) frame, so this uses outputUV.
      vec2 focusDelta = (outputUV - vec2(uBlurFocusX, uBlurFocusY)) * aspectScale;
      float focusDist = length(focusDelta);
      float sharpRadius = uBlurSize * 0.5;
      blurMask = smoothstep(sharpRadius, sharpRadius + 0.25, focusDist);
    }
    if (blurMask > 0.001) {
      vec3 blurred = bokehBlur(
        uv, uBlurAmount * 0.04, aspectScale, uBlurBokehShape, uBlurCatEye, uBlurBoost
      );
      c = mix(rawSharp, blurred, blurMask);
    }
  }

  // Sharpen — classic 4-neighbor unsharp mask. Samples uTexture directly
  // (raw) rather than the already-processed working color, since a
  // single-pass shader has no way to know a neighboring pixel's fully
  // processed value without re-running the whole pipeline for it too.
  if (uEffectSharpen > 0.001) {
    vec2 texel = 1.0 / uSize;
    vec3 nUp = texture(uTexture, uv + vec2(0.0, -texel.y)).rgb;
    vec3 nDown = texture(uTexture, uv + vec2(0.0, texel.y)).rgb;
    vec3 nLeft = texture(uTexture, uv + vec2(-texel.x, 0.0)).rgb;
    vec3 nRight = texture(uTexture, uv + vec2(texel.x, 0.0)).rgb;
    vec3 edge = rawSharp * 4.0 - nUp - nDown - nLeft - nRight;
    c += edge * uEffectSharpen * 0.3;
  }

  // Clarity — local/midtone contrast: pushes each pixel away from a
  // softly blurred version of itself, the way real clarity tools work.
  // Reuses bokehBlur at a fixed moderate radius, plain circular shape.
  if (uEffectClarity != 0.0) {
    vec3 softBlur = bokehBlur(uv, 0.025, aspectScale, 0.0, 0.0, 0.0);
    c += (c - softBlur) * uEffectClarity * 0.7;
  }

  // Dehaze — lifts the black point and stretches contrast (haze's main
  // visual signature is that blacks aren't truly black), plus a mild
  // saturation boost to counter the flatness haze causes. Negative
  // values do the reverse — add a haze-like flatness instead.
  if (uEffectDehaze != 0.0) {
    float lift = uEffectDehaze * 0.22;
    c = (c - lift) / max(1.0 - lift, 0.15);
    float dehazeGray = luma(c);
    c = mix(vec3(dehazeGray), c, 1.0 + max(uEffectDehaze, 0.0) * 0.3);
  }
  c = clamp(c, 0.0, 1.0);

  // Exposure — multiplicative, roughly in stops.
  c *= pow(2.0, uExposure * 2.0);

  // Brightness — simple linear offset.
  c += uBrightness * 0.35;

  // Contrast — pivot around mid-gray.
  c = (c - 0.5) * (1.0 + uContrast) + 0.5;

  float l = luma(c);

  // Highlights / Shadows — tone-region-limited lift & gain.
  float highlightW = smoothstep(0.45, 1.0, l);
  float shadowW = 1.0 - smoothstep(0.0, 0.55, l);
  c += uHighlights * 0.6 * highlightW * (1.0 - c);
  c += uShadows * 0.6 * shadowW * c;

  // Whites / Blacks — clip-point style push at the extremes.
  float whiteW = smoothstep(0.7, 1.0, l);
  float blackW = 1.0 - smoothstep(0.0, 0.3, l);
  c += uWhites * 0.5 * whiteW;
  c += uBlacks * 0.5 * blackW;

  // Clamp before the curve lookup so texture coordinates stay well-defined.
  c = clamp(c, 0.0, 1.0);

  // Tone curve — one lookup per channel, each at that channel's own value.
  vec3 curved;
  curved.r = texture(uCurveLUT, vec2(c.r, 0.5)).r;
  curved.g = texture(uCurveLUT, vec2(c.g, 0.5)).g;
  curved.b = texture(uCurveLUT, vec2(c.b, 0.5)).b;
  c = curved;

  // Warmth — shift the red/blue balance.
  c.r += uWarmth * 0.18;
  c.b -= uWarmth * 0.18;

  // Tint — shift the green/magenta balance.
  c.g += uTint * 0.18;
  c.r -= uTint * 0.09;
  c.b -= uTint * 0.09;

  // Saturation — uniform blend toward grayscale.
  float gray = luma(c);
  c = mix(vec3(gray), c, 1.0 + uSaturation);

  // Vibrance — smarter saturation that favors already-muted pixels.
  float maxC = max(c.r, max(c.g, c.b));
  float minC = min(c.r, min(c.g, c.b));
  float sat = maxC - minC;
  float vibAmount = uVibrance * (1.0 - sat);
  float grayV = luma(c);
  c = mix(vec3(grayV), c, 1.0 + vibAmount);

  c = clamp(c, 0.0, 1.0);

  // Color Grading — tints shadows/midtones/highlights independently,
  // based on the image's own luminance at this point in the pipeline.
  // uGradeBlending widens or narrows how much the three ranges overlap.
  float gl = luma(c);
  float blendWidth = mix(0.12, 0.4, uGradeBlending);
  float gShadowW = 1.0 - smoothstep(0.0, blendWidth * 2.0, gl);
  float gHighW = smoothstep(1.0 - blendWidth * 2.0, 1.0, gl);
  float gMidW = clamp(1.0 - gShadowW - gHighW, 0.0, 1.0);

  vec3 shadowTint = hueToRgb(uGradeShadowHue) - 0.5;
  vec3 midTint = hueToRgb(uGradeMidHue) - 0.5;
  vec3 highTint = hueToRgb(uGradeHighHue) - 0.5;

  c += shadowTint * uGradeShadowSat * gShadowW * 0.5;
  c += midTint * uGradeMidSat * gMidW * 0.5;
  c += highTint * uGradeHighSat * gHighW * 0.5;

  c += uGradeShadowLum * 0.4 * gShadowW;
  c += uGradeMidLum * 0.4 * gMidW;
  c += uGradeHighLum * 0.4 * gHighW;

  c = clamp(c, 0.0, 1.0);

  // Masking — local adjustments, applied after global grading but before
  // the final Vignette/Grain finishing touches.
  c = applyMaskSlot(
    c, outputUV, uv, uMask0Type, uMask0Invert, uMask0P0, uMask0P1, uMask0P2, uMask0P3, uMask0P4,
    uMask0Exposure, uMask0Contrast, uMask0Saturation, uMask0Warmth, texture(uMask0Brush, uv).r
  );
  c = applyMaskSlot(
    c, outputUV, uv, uMask1Type, uMask1Invert, uMask1P0, uMask1P1, uMask1P2, uMask1P3, uMask1P4,
    uMask1Exposure, uMask1Contrast, uMask1Saturation, uMask1Warmth, texture(uMask1Brush, uv).r
  );
  c = applyMaskSlot(
    c, outputUV, uv, uMask2Type, uMask2Invert, uMask2P0, uMask2P1, uMask2P2, uMask2P3, uMask2P4,
    uMask2Exposure, uMask2Contrast, uMask2Saturation, uMask2Warmth, texture(uMask2Brush, uv).r
  );
  c = applyMaskSlot(
    c, outputUV, uv, uMask3Type, uMask3Invert, uMask3P0, uMask3P1, uMask3P2, uMask3P3, uMask3P4,
    uMask3Exposure, uMask3Contrast, uMask3Saturation, uMask3Warmth, texture(uMask3Brush, uv).r
  );
  c = applyMaskSlot(
    c, outputUV, uv, uMask4Type, uMask4Invert, uMask4P0, uMask4P1, uMask4P2, uMask4P3, uMask4P4,
    uMask4Exposure, uMask4Contrast, uMask4Saturation, uMask4Warmth, texture(uMask4Brush, uv).r
  );
  c = applyMaskSlot(
    c, outputUV, uv, uMask5Type, uMask5Invert, uMask5P0, uMask5P1, uMask5P2, uMask5P3, uMask5P4,
    uMask5Exposure, uMask5Contrast, uMask5Saturation, uMask5Warmth, texture(uMask5Brush, uv).r
  );

  // Vignette — darkens (or, with a negative amount, lightens) the CURRENT
  // frame's edges (outputUV, not the raw image), so it looks right
  // relative to whatever's actually cropped into view.
  if (uEffectVignetteAmount != 0.0) {
    vec2 vCentered = (outputUV - 0.5) * aspectScale;
    float vDist = length(vCentered);
    float vInner = mix(0.15, 0.75, uEffectVignetteSize);
    float vig = smoothstep(vInner, vInner + 0.55, vDist);
    c *= (1.0 - vig * max(uEffectVignetteAmount, 0.0) * 0.85);
    c += vig * max(-uEffectVignetteAmount, 0.0) * 0.5;
  }

  // Grain — blocky per-cell pseudo-random noise over the CURRENT frame
  // (outputUV), added last as a finishing texture over the fully graded
  // image, the way real film grain or a noise overlay would be applied.
  if (uEffectGrainAmount > 0.001) {
    float grainFreq = mix(300.0, 30.0, uEffectGrainSize);
    vec2 grainCell = floor(outputUV * aspectScale * grainFreq);
    float n = fract(sin(dot(grainCell, vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
    c += n * uEffectGrainAmount * 0.3;
  }

  c = clamp(c, 0.0, 1.0);

  fragColor = vec4(c, src.a);
}
