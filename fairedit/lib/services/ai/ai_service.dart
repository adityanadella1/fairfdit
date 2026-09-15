import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/mask_state.dart';
import 'ai_config.dart';

/// Raised for every failure crossing the AI boundary, so callers have one
/// type to catch and one user-readable [message] to show. The technical
/// detail stays in [detail] for logs.
class AiException implements Exception {
  final String message;
  final Object? detail;

  const AiException(this.message, [this.detail]);

  @override
  String toString() => 'AiException: $message${detail == null ? '' : ' ($detail)'}';
}

/// A mask returned by the segmentation service.
class AiMaskResult {
  /// Greyscale coverage as RGBA bytes (all channels equal), ready to hand
  /// straight to `ShaderEngine.decodePixels`.
  final Uint8List rgbaBytes;
  final int width;
  final int height;

  /// The model's own confidence in this mask, 0..1. Surfaced in the UI so
  /// a weak match reads as "try a different prompt" rather than as a bug.
  final double score;

  /// Normalised bounding box of the selection (l, t, r, b), when the
  /// pipeline went through a detector. Null for whole-frame modes.
  final List<double>? box;

  const AiMaskResult({
    required this.rgbaBytes,
    required this.width,
    required this.height,
    required this.score,
    this.box,
  });
}

/// Client for the FairEdit AI backend.
///
/// Deliberately the only place in the app that knows the wire format. The
/// provider talks in `ui.Image`s and [AiMaskMode]s; everything about
/// base64, multipart and HTTP status codes stops here.
class AiService {
  AiService._();
  static final AiService instance = AiService._();

  final http.Client _client = http.Client();

  /// Cached health result. Probing on every panel build would put a
  /// network round-trip in front of a UI frame; probing once and
  /// re-probing on a set interval keeps the "AI Remove" affordance
  /// honest without that cost.
  bool _available = false;
  DateTime? _lastProbe;
  static const _probeInterval = Duration(seconds: 30);

  bool get lastKnownAvailability => _available;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (AiConfig.apiKey.isNotEmpty) 'X-API-Key': AiConfig.apiKey,
      };

  Uri _uri(String path) => Uri.parse('${AiConfig.baseUrl}$path');

  /// Cheap liveness probe. Never throws — an unreachable backend is an
  /// expected state (offline, on a plane, backend not started), not an
  /// error the user needs to see as a dialog.
  Future<bool> checkAvailability({bool force = false}) async {
    final last = _lastProbe;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _probeInterval) {
      return _available;
    }
    _lastProbe = DateTime.now();
    try {
      final res = await _client
          .get(_uri('/v1/health'), headers: _headers)
          .timeout(AiConfig.healthTimeout);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      _available = res.statusCode == 200 && body['status'] == 'ok';
    } catch (e) {
      if (kDebugMode) debugPrint('AI backend unreachable: $e');
      _available = false;
    }
    return _available;
  }

  /// POST /v1/segment — runs the pipeline for [mode] and returns one mask.
  ///
  /// [imagePng] must be the *raw* image (pre-crop, pre-adjustment): masks
  /// are stored in raw-image space so they survive later crop and rotate
  /// edits, exactly like the hand-painted brush textures.
  Future<AiMaskResult> segment({
    required Uint8List imagePng,
    required AiMaskMode mode,
    String? prompt,
  }) async {
    if (mode.needsPrompt && (prompt == null || prompt.trim().isEmpty)) {
      throw const AiException('Type what you want to select first.');
    }

    final body = jsonEncode({
      'mode': mode.wireName,
      'image': base64Encode(imagePng),
      if (prompt != null && prompt.trim().isNotEmpty) 'prompt': prompt.trim(),
      'output': 'png',
      'refine_edges': true,
    });

    final json = await _post(
      '/v1/segment',
      body,
      AiConfig.segmentTimeout,
      whatFailed: 'Selection',
    );

    final maskB64 = json['mask'] as String?;
    if (maskB64 == null) {
      throw const AiException('The server returned no mask.');
    }
    final decoded = await _decodeToGreyscaleRgba(base64Decode(maskB64));

    return AiMaskResult(
      rgbaBytes: decoded.$1,
      width: decoded.$2,
      height: decoded.$3,
      score: (json['score'] as num?)?.toDouble() ?? 0,
      box: (json['box'] as List?)?.map((e) => (e as num).toDouble()).toList(),
    );
  }

  /// POST /v1/remove — LaMa inpaint of [maskPng] out of [imagePng].
  /// Returns PNG bytes of the result at the same dimensions as the input.
  Future<Uint8List> remove({
    required Uint8List imagePng,
    required Uint8List maskPng,
  }) async {
    final body = jsonEncode({
      'image': base64Encode(imagePng),
      'mask': base64Encode(maskPng),
      'dilate': 8,
    });

    final json = await _post(
      '/v1/remove',
      body,
      AiConfig.removeTimeout,
      whatFailed: 'AI Remove',
    );

    final resultB64 = json['image'] as String?;
    if (resultB64 == null) {
      throw const AiException('The server returned no image.');
    }
    return base64Decode(resultB64);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    String body,
    Duration timeout, {
    required String whatFailed,
  }) async {
    http.Response res;
    try {
      res = await _client
          .post(_uri(path), headers: _headers, body: body)
          .timeout(timeout);
    } on TimeoutException {
      throw AiException('$whatFailed timed out. The server may be busy.');
    } catch (e) {
      _available = false;
      throw AiException(
        '$whatFailed could not reach the server. Check your connection.',
        e,
      );
    }

    if (res.statusCode == 200) {
      _available = true;
      try {
        return jsonDecode(res.body) as Map<String, dynamic>;
      } catch (e) {
        throw AiException('$whatFailed returned an unreadable response.', e);
      }
    }

    // FastAPI puts our own message in `detail`; fall back to the status
    // line for anything that did not come from the app (a proxy, say).
    String detail = 'HTTP ${res.statusCode}';
    try {
      final parsed = jsonDecode(res.body);
      if (parsed is Map && parsed['detail'] != null) {
        detail = parsed['detail'].toString();
      }
    } catch (_) {
      // Leave the status line.
    }
    if (res.statusCode == 404 || res.statusCode == 422) {
      throw AiException('Nothing matched that selection. $detail');
    }
    throw AiException('$whatFailed failed: $detail');
  }

  /// Decodes PNG bytes and flattens them to RGBA where every channel
  /// carries the coverage value. The shader samples `.r`, but keeping all
  /// four channels in step means the same texture previews correctly if
  /// it is ever drawn directly (e.g. a mask overlay).
  Future<(Uint8List, int, int)> _decodeToGreyscaleRgba(Uint8List pngBytes) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        throw const AiException('Could not read the returned mask.');
      }
      final src = data.buffer.asUint8List();
      final out = Uint8List(src.length);
      for (var i = 0; i < src.length; i += 4) {
        // The backend encodes coverage in the luminance of an opaque
        // greyscale PNG, so any colour channel is the value; red is the
        // one the shader reads.
        final v = src[i];
        out[i] = v;
        out[i + 1] = v;
        out[i + 2] = v;
        out[i + 3] = 255;
      }
      return (out, image.width, image.height);
    } finally {
      image.dispose();
    }
  }

  void dispose() => _client.close();
}
