import 'dart:math' as math;

import 'animation.dart';
import 'motion_path.dart';
import 'values.dart';

final RegExp _pathFunction = RegExp(r'''^path\(\s*(?:'([^']*)'|"([^"]*)"|([^)]*))\s*\)$''');

/// The CSS motion path declared on an element by `offset-path`.
///
/// CSS positions an element along a path with `offset-path` plus an animated
/// `offset-distance`, where SMIL would use `<animateMotion>`. Neither the
/// renderer nor the SVG parser understands those properties, so the motion is
/// resolved here into the `transform` it is equivalent to.
///
/// This is the shape that tools which export animated SVGs, notably SVGator,
/// use for everything that moves.
class OffsetPath {
  OffsetPath._(this._path, this._tracksPath, this._fixedRotation);

  /// Reads the motion path out of an element's resolved declarations.
  ///
  /// Returns null when the element declares no usable path, including for the
  /// shapes `offset-path` allows that are not a `path()`, such as `ray()` or a
  /// `url()` reference.
  static OffsetPath? parse(Map<String, String> declarations) {
    final String? rawPath = declarations['offset-path'];
    if (rawPath == null) {
      return null;
    }
    final RegExpMatch? match = _pathFunction.firstMatch(rawPath.trim());
    if (match == null) {
      return null;
    }
    final String? pathData = match.group(1) ?? match.group(2) ?? match.group(3);
    if (pathData == null) {
      return null;
    }
    final MotionPath? path = MotionPath.parse(pathData);
    if (path == null) {
      return null;
    }

    final String rotate = declarations['offset-rotate']?.trim() ?? 'auto';
    final bool tracksPath = rotate == 'auto' || rotate.startsWith('auto ');
    final bool reversed = rotate == 'reverse' || rotate.startsWith('auto ') && rotate.contains('-');
    final NumberListValue? angle = NumberListValue.parse(
      rotate.replaceFirst('auto', '').replaceFirst('reverse', '').trim(),
    );
    return OffsetPath._(
      path,
      tracksPath || rotate == 'reverse',
      (angle?.numbers.first ?? 0) + (reversed ? 180 : 0),
    );
  }

  final MotionPath _path;
  final bool _tracksPath;
  final double _fixedRotation;

  /// The transform that places an element at [distance] along the path, where
  /// [distance] is a fraction from 0.0 to 1.0.
  TransformListValue transformAt(double distance) {
    final MotionPathSample sample = _path.sampleAtFraction(distance);
    final double angle = _tracksPath ? sample.angleInDegrees + _fixedRotation : _fixedRotation;
    return TransformListValue(<TransformValue>[
      TransformValue('translate', <double>[sample.x, sample.y]),
      // Written even when the angle is zero, so that every keyframe of an
      // animation has the same shape and stays interpolable.
      if (_tracksPath || angle != 0) TransformValue('rotate', <double>[angle]),
    ]);
  }

  /// The transform for a static `offset-distance`, or for the start of the path
  /// when none was given.
  TransformListValue transformFor(String? offsetDistance) => transformAt(
    _toFraction(offsetDistance == null ? null : NumberListValue.parse(offsetDistance)),
  );

  /// How many samples a converted motion is described by.
  ///
  /// The path between two key frames is a curve, not a straight line, so the
  /// key frames alone would send the element across the chord between them.
  /// Extra samples are taken to follow the path, and are spread over the
  /// intervals in proportion to how far the element travels in each, so that a
  /// motion crammed into a tenth of the timeline is still described smoothly.
  static const int _samples = 64;

  /// Rewrites an animation of `offset-distance` as the equivalent animation of
  /// `transform`.
  ///
  /// Timing is carried over untouched. Easing is not: it is baked into the
  /// positions of the samples, which is what lets the result be interpolated
  /// linearly and still arrive where the easing asked for.
  SvgAttributeAnimation toTransformAnimation(SvgAttributeAnimation animation) {
    final List<double> distances = <double>[
      for (final AnimatableValue value in animation.values)
        _toFraction(value is NumberListValue ? value : null),
    ];
    final List<double> spans = <double>[
      for (var i = 0; i < distances.length - 1; i += 1) (distances[i + 1] - distances[i]).abs(),
    ];
    final double travelled = spans.fold(0.0, (double sum, double span) => sum + span);

    final keyTimes = <double>[animation.keyTimes.first];
    final values = <AnimatableValue>[transformAt(distances.first)];
    for (var i = 0; i < spans.length; i += 1) {
      final double share = travelled <= 0 ? 0 : spans[i] / travelled;
      final int steps = math.max(1, (share * _samples).round());
      final double startTime = animation.keyTimes[i];
      final double endTime = animation.keyTimes[i + 1];
      for (var step = 1; step <= steps; step += 1) {
        final double t = step / steps;
        final double eased = animation.keySplines == null
            ? t
            : animation.keySplines![i].transform(t);
        keyTimes.add(startTime + (endTime - startTime) * t);
        values.add(transformAt(distances[i] + (distances[i + 1] - distances[i]) * eased));
      }
    }

    return SvgAttributeAnimation(
      attributeName: 'transform',
      values: values,
      keyTimes: keyTimes,
      timing: animation.timing,
      // The motion places the element within its parent, so it wraps around
      // whatever transform the element already carries.
      additive: true,
      prependsToUnderlyingValue: true,
    );
  }

  /// Converts an `offset-distance` value to a fraction of the path length.
  ///
  /// Percentages are relative to the total length; a bare number or a length is
  /// an absolute distance along it.
  double _toFraction(NumberListValue? value) {
    if (value == null || value.numbers.isEmpty) {
      return 0;
    }
    final double amount = value.numbers.first;
    if (value.unit == '%') {
      return amount / 100;
    }
    return _path.length <= 0 ? 0 : amount / _path.length;
  }
}
