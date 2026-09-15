import 'package:flutter/material.dart';

/// Establishes the single AspectRatio box that the photo and whichever
/// interaction overlay is active (Blur's ring, Crop's rect, ...) share.
/// Splitting this out of EditorCanvas is what lets an overlay line up
/// pixel-for-pixel with the photo underneath it.
class EditorImageStack extends StatelessWidget {
  final double aspectRatio;
  final Widget canvas;
  final Widget? overlay;

  const EditorImageStack({
    super.key,
    required this.aspectRatio,
    required this.canvas,
    this.overlay,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: [
          canvas,
          if (overlay != null) overlay!,
        ],
      ),
    );
  }
}
