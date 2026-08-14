import 'dart:math' as math;

import 'package:path_parsing/path_parsing.dart';

/// The number of line segments each cubic is flattened into.
///
/// `<animateMotion>` paths are sampled for position and heading only, so a
/// fixed subdivision is accurate enough and keeps parsing cost predictable.
const int _cubicSegments = 24;

/// A point along a motion path, together with the direction of travel there.
class MotionPathSample {
  /// Creates a sample at ([x], [y]) heading [angleInDegrees].
  const MotionPathSample(this.x, this.y, this.angleInDegrees);

  /// The horizontal position in user units.
  final double x;

  /// The vertical position in user units.
  final double y;

  /// The direction of travel, in degrees clockwise from the positive x axis.
  final double angleInDegrees;
}

/// An SVG path flattened into a polyline that can be sampled by arc length.
///
/// Used to evaluate `<animateMotion>`, which moves its target along a path
/// rather than between attribute values.
class MotionPath implements PathProxy {
  MotionPath._();

  /// Flattens the path described by [pathData], as it would appear in a `d`
  /// attribute.
  ///
  /// Returns null if the path is empty or cannot be parsed.
  static MotionPath? parse(String pathData) {
    if (pathData.trim().isEmpty) {
      return null;
    }
    final path = MotionPath._();
    try {
      writeSvgPathDataToPath(pathData, path);
    } on Object {
      // Malformed path data is ignored the same way the SVG parser ignores it,
      // rather than failing the whole picture.
      return null;
    }
    if (path._points.length < 2) {
      return null;
    }
    return path;
  }

  final List<double> _points = <double>[];
  final List<double> _lengths = <double>[0.0];
  double _startX = 0;
  double _startY = 0;
  double _currentX = 0;
  double _currentY = 0;
  bool _hasCurrent = false;

  /// The total length of the path in user units.
  double get length => _lengths.last;

  void _addPoint(double x, double y, {required bool connected}) {
    if (_points.isNotEmpty && connected) {
      final double dx = x - _points[_points.length - 2];
      final double dy = y - _points[_points.length - 1];
      _lengths.add(_lengths.last + math.sqrt(dx * dx + dy * dy));
    } else if (_points.isNotEmpty) {
      // A subpath break moves without drawing, so it adds no length.
      _lengths.add(_lengths.last);
    }
    _points
      ..add(x)
      ..add(y);
    _currentX = x;
    _currentY = y;
    _hasCurrent = true;
  }

  @override
  void moveTo(double x, double y) {
    _startX = x;
    _startY = y;
    _addPoint(x, y, connected: false);
  }

  @override
  void lineTo(double x, double y) {
    if (!_hasCurrent) {
      moveTo(x, y);
      return;
    }
    _addPoint(x, y, connected: true);
  }

  @override
  void cubicTo(double x1, double y1, double x2, double y2, double x3, double y3) {
    final double x0 = _currentX;
    final double y0 = _currentY;
    for (var i = 1; i <= _cubicSegments; i += 1) {
      final double t = i / _cubicSegments;
      final double inverse = 1 - t;
      final double a = inverse * inverse * inverse;
      final double b = 3 * inverse * inverse * t;
      final double c = 3 * inverse * t * t;
      final double d = t * t * t;
      _addPoint(
        a * x0 + b * x1 + c * x2 + d * x3,
        a * y0 + b * y1 + c * y2 + d * y3,
        connected: true,
      );
    }
  }

  @override
  void close() {
    if (_hasCurrent) {
      _addPoint(_startX, _startY, connected: true);
    }
  }

  /// Samples the path at [fraction] of its total length, from 0.0 to 1.0.
  MotionPathSample sampleAtFraction(double fraction) {
    final double target = (fraction.clamp(0.0, 1.0)) * length;
    var index = 0;
    while (index < _lengths.length - 2 && _lengths[index + 1] < target) {
      index += 1;
    }
    final double segmentStart = _lengths[index];
    final double segmentLength = _lengths[index + 1] - segmentStart;
    final double t = segmentLength <= 0 ? 0.0 : (target - segmentStart) / segmentLength;
    final double x0 = _points[index * 2];
    final double y0 = _points[index * 2 + 1];
    final double x1 = _points[index * 2 + 2];
    final double y1 = _points[index * 2 + 3];
    return MotionPathSample(
      x0 + (x1 - x0) * t,
      y0 + (y1 - y0) * t,
      math.atan2(y1 - y0, x1 - x0) * 180 / math.pi,
    );
  }
}
