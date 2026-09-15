/// Where the AI backend lives and how long we are willing to wait for it.
///
/// The base URL is a compile-time constant so a release build cannot be
/// pointed at a developer machine by accident:
///
/// ```
/// flutter run --dart-define=FAIREDIT_AI_BASE_URL=http://192.168.1.20:8000
/// ```
///
/// The default is the Android emulator's alias for the host loopback,
/// which is the address that works out of the box for the common case of
/// running the backend with docker compose on the same machine.
class AiConfig {
  AiConfig._();

  static const baseUrl = String.fromEnvironment(
    'FAIREDIT_AI_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  static const apiKey = String.fromEnvironment('FAIREDIT_AI_API_KEY');

  /// Segmentation is a single forward pass through Grounding DINO and
  /// SAM 2 — slow on CPU, around a second on a warm GPU.
  static const segmentTimeout = Duration(seconds: 45);

  /// LaMa inpainting over a full-size image, plus transfer of the result.
  static const removeTimeout = Duration(seconds: 90);

  /// Health probes must fail fast: the UI blocks on this before it can
  /// decide whether to offer AI features at all.
  static const healthTimeout = Duration(seconds: 4);

  /// Longest edge the client uploads. Sending a 48MP original would
  /// dominate the request with transfer time for no gain in mask
  /// quality — the mask is upscaled back to full resolution on arrival.
  static const uploadMaxDimension = 1536;
}
