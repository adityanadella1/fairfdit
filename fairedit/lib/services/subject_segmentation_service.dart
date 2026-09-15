import 'dart:typed_data';

import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';

/// Result of on-device subject detection: RGBA bytes at the mask's own
/// width/height, red channel = subject confidence (0..255), ready to
/// decode straight into a shader-sampleable ui.Image.
class SubjectMaskResult {
  final int width;
  final int height;
  final Uint8List rgbaBytes;

  const SubjectMaskResult({
    required this.width,
    required this.height,
    required this.rgbaBytes,
  });
}

/// Runs Google ML Kit's Selfie Segmentation entirely on-device — no
/// network call, no API key, no per-image cost. It's person-shaped
/// subjects specifically (not arbitrary objects), which matches "select
/// the person in this photo" directly.
class SubjectSegmentationService {
  SubjectSegmentationService._();
  static final SubjectSegmentationService instance = SubjectSegmentationService._();

  Future<SubjectMaskResult> detectSubjectMask(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    // A fresh segmenter per call, closed immediately after — this is a
    // deliberate one-off user action (tapping "Select Subject"), not a
    // hot path, so the simpler lifecycle is worth it over keeping one
    // instance alive and managing its state across calls.
    final segmenter = SelfieSegmenter(
      mode: SegmenterMode.single,
      // false keeps the mask's dimensions identical to the input image's
      // own width/height — guarantees pixel/aspect-ratio alignment with
      // the photo without any extra scaling math.
      enableRawSizeMask: false,
    );

    try {
      final mask = await segmenter.processImage(inputImage);
      if (mask == null) {
        throw StateError('No subject could be detected in this photo.');
      }

      final width = mask.width;
      final height = mask.height;
      final confidences = mask.confidences;
      final bytes = Uint8List(width * height * 4);

      for (var i = 0; i < width * height; i++) {
        final v = (confidences[i].clamp(0.0, 1.0) * 255).round();
        final o = i * 4;
        bytes[o] = v;
        bytes[o + 1] = v;
        bytes[o + 2] = v;
        bytes[o + 3] = 255;
      }

      return SubjectMaskResult(width: width, height: height, rgbaBytes: bytes);
    } finally {
      segmenter.close();
    }
  }
}
