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

/// Keeps a run of headings continuous where `atan2` is not.
///
/// A heading comes from `atan2`, which answers in (-180, 180], so it jumps by
/// nearly a whole turn the moment the direction of travel crosses 180 degrees —
/// which is to say, whenever something is travelling leftwards. The keyframes
/// either side of that jump are interpolated linearly, so a step of -355.8
/// degrees is not read as "carry on turning" but as "turn almost all the way
/// round the other way", and the element spins.
///
/// Whole turns are added instead. The orientation each keyframe describes does
/// not change and the step between them becomes the small one it should always
/// have been. Going right round a closed path therefore accumulates a turn by
/// the last keyframe, which is what one revolution is; playback restarting from
/// the first keyframe is a whole turn and invisible.
///
/// Not fixable where the interpolating happens instead: a rotation cannot be
/// made to always take the short way round without breaking `from="0" to="720"`,
/// which is two deliberate turns and has to sweep both of them.
class ContinuousHeading {
  double? _previous;

  /// [degrees] shifted by whole turns to land within 180 degrees of the heading
  /// before it.
  double next(double degrees) {
    final double? previous = _previous;
    if (previous == null) {
      return _previous = degrees;
    }
    return _previous = degrees + 360 * ((previous - degrees) / 360).roundToDouble();
  }
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
    return MotionPathSample(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, _headingAt(index));
  }

  /// The direction of the chord at [index], or of the nearest chord that has
  /// one.
  ///
  /// A chord with no length has no direction, and `atan2(0, 0)` answers zero
  /// rather than admitting that, which would point a tracking element to the
  /// right for as long as a sample sat there. They arrive from the `Z` of a path
  /// whose last segment already ended where it started, and from the move
  /// between two subpaths, which covers ground without drawing.
  ///
  /// Looks back before it looks forward, so something standing on a repeated
  /// point keeps the direction it arrived with rather than snapping early to
  /// the one it is about to take.
  double _headingAt(int index) {
    for (var distance = 0; distance < _lengths.length; distance += 1) {
      for (final int at in <int>[index - distance, index + distance]) {
        if (at < 0 || at > _lengths.length - 2 || _lengths[at + 1] <= _lengths[at]) {
          continue;
        }
        return math.atan2(
              _points[at * 2 + 3] - _points[at * 2 + 1],
              _points[at * 2 + 2] - _points[at * 2],
            ) *
            180 /
            math.pi;
      }
    }
    // Every chord is degenerate, so the whole path is a point and there is no
    // direction to be had.
    return 0;
  }
}
