import 'package:flutter/foundation.dart';

/// A single control point on a tone curve. x = input level, y = output
/// level, both 0.0..1.0.
@immutable
class CurvePoint {
  final double x;
  final double y;

  const CurvePoint(this.x, this.y);

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  factory CurvePoint.fromJson(Map<String, dynamic> json) => CurvePoint(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is CurvePoint && x == other.x && y == other.y);

  @override
  int get hashCode => Object.hash(x, y);
}

/// The set of control points for one curve (master, red, green, or blue).
/// Always has at least the two endpoints, at x=0 and x=1.
@immutable
class ChannelCurve {
  final List<CurvePoint> points;

  const ChannelCurve(this.points);

  static const ChannelCurve identity = ChannelCurve(<CurvePoint>[
    CurvePoint(0, 0),
    CurvePoint(1, 1),
  ]);

  bool get isIdentity =>
      points.length == 2 &&
      points[0].x == 0 &&
      points[0].y == 0 &&
      points[1].x == 1 &&
      points[1].y == 1;

  List<dynamic> toJson() => points.map((p) => p.toJson()).toList();

  factory ChannelCurve.fromJson(List<dynamic> json) => ChannelCurve(
        json.map((e) => CurvePoint.fromJson(e as Map<String, dynamic>)).toList(),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ChannelCurve && listEquals(points, other.points));

  @override
  int get hashCode => Object.hashAll(points);
}

enum CurveChannel { master, red, green, blue }

/// All four curves for one photo. [master] applies to all three channels
/// first; [red]/[green]/[blue] then apply on top of that per channel —
/// see buildCurveLutBytes for exactly how they're composed.
@immutable
class CurvesState {
  final ChannelCurve master;
  final ChannelCurve red;
  final ChannelCurve green;
  final ChannelCurve blue;

  const CurvesState({
    this.master = ChannelCurve.identity,
    this.red = ChannelCurve.identity,
    this.green = ChannelCurve.identity,
    this.blue = ChannelCurve.identity,
  });

  bool get isNeutral =>
      master.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity;

  ChannelCurve forChannel(CurveChannel channel) {
    switch (channel) {
      case CurveChannel.master:
        return master;
      case CurveChannel.red:
        return red;
      case CurveChannel.green:
        return green;
      case CurveChannel.blue:
        return blue;
    }
  }

  CurvesState withChannel(CurveChannel channel, ChannelCurve curve) {
    switch (channel) {
      case CurveChannel.master:
        return copyWith(master: curve);
      case CurveChannel.red:
        return copyWith(red: curve);
      case CurveChannel.green:
        return copyWith(green: curve);
      case CurveChannel.blue:
        return copyWith(blue: curve);
    }
  }

  CurvesState copyWith({
    ChannelCurve? master,
    ChannelCurve? red,
    ChannelCurve? green,
    ChannelCurve? blue,
  }) {
    return CurvesState(
      master: master ?? this.master,
      red: red ?? this.red,
      green: green ?? this.green,
      blue: blue ?? this.blue,
    );
  }

  Map<String, dynamic> toJson() => {
        'master': master.toJson(),
        'red': red.toJson(),
        'green': green.toJson(),
        'blue': blue.toJson(),
      };

  factory CurvesState.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const CurvesState();
    ChannelCurve read(String key) {
      final v = json[key];
      if (v is List) {
        try {
          return ChannelCurve.fromJson(v);
        } catch (_) {
          return ChannelCurve.identity;
        }
      }
      return ChannelCurve.identity;
    }

    return CurvesState(
      master: read('master'),
      red: read('red'),
      green: read('green'),
      blue: read('blue'),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CurvesState &&
          master == other.master &&
          red == other.red &&
          green == other.green &&
          blue == other.blue);

  @override
  int get hashCode => Object.hash(master, red, green, blue);
}
