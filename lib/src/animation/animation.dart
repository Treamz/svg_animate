import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

import 'timing.dart';
import 'values.dart';

/// The largest number of iterations that `accumulate="sum"` will fold together.
///
/// Accumulation over an unbounded number of iterations has no useful visual
/// result and would make sampling cost grow without limit, so it saturates.
const int _maxAccumulatedIterations = 1000;

/// One animation of one attribute of one element.
///
/// This is the resolved form of an SVG `<animate>`, `<animateTransform>`,
/// `<animateMotion>`, or `<set>` element, or of one CSS `@keyframes` property
/// track. Parsing has already turned the source syntax into a list of
/// [values] positioned at [keyTimes], so sampling is the same for all of them.
@immutable
class SvgAttributeAnimation {
  /// Creates an animation of [attributeName].
  ///
  /// [values] must not be empty, and [keyTimes] must have the same length,
  /// start at 0.0, and increase monotonically.
  SvgAttributeAnimation({
    required this.attributeName,
    required this.values,
    required this.keyTimes,
    required this.timing,
    this.calcMode = SvgCalcMode.linear,
    this.keySplines,
    this.additive = false,
    this.accumulate = false,
    this.prependsToUnderlyingValue = false,
  }) : assert(values.isNotEmpty),
       assert(values.length == keyTimes.length),
       assert(
         keySplines == null || keySplines.length >= values.length - 1,
         'A spline is required between each pair of values.',
       );

  /// The name of the attribute this animation writes to.
  ///
  /// For `<animateTransform>` and CSS `transform` animations this is
  /// `transform`.
  final String attributeName;

  /// The values this animation moves between, in order.
  final List<AnimatableValue> values;

  /// The point within a single iteration, from 0.0 to 1.0, at which each entry
  /// of [values] is reached.
  final List<double> keyTimes;

  /// When and for how long this animation runs.
  final SvgAnimationTiming timing;

  /// How values are distributed between key times.
  ///
  /// [SvgCalcMode.paced] is resolved into evenly paced [keyTimes] while
  /// parsing, so it never reaches sampling.
  final SvgCalcMode calcMode;

  /// The easing applied to each interval when [calcMode] is
  /// [SvgCalcMode.spline].
  final List<Curve>? keySplines;

  /// Whether this animation adds to the value beneath it rather than replacing
  /// it, as requested by `additive="sum"`.
  final bool additive;

  /// Whether each repeat starts from where the previous one ended, as
  /// requested by `accumulate="sum"`.
  final bool accumulate;

  /// Whether this animation composes in front of the value beneath it rather
  /// than behind it.
  ///
  /// Only `<animateMotion>` does this: it moves the element within its parent's
  /// coordinate system, so its transform wraps around whatever transform the
  /// element already has. Ignored unless [additive] is true.
  final bool prependsToUnderlyingValue;

  /// Whether this animation ever produces a value after [time].
  ///
  /// Used to decide how long the document as a whole runs for.
  Duration? get activeEnd => timing.activeEnd;

  /// The value this animation contributes at [time], measured from the start of
  /// the document, or null when it contributes nothing.
  AnimatableValue? valueAt(Duration time) {
    final SvgAnimationSample? sample = sampleTiming(timing, time);
    if (sample == null) {
      return null;
    }
    AnimatableValue value = _interpolate(sample.fraction);
    if (accumulate && sample.iteration > 0) {
      final int iterations = sample.iteration.clamp(0, _maxAccumulatedIterations);
      final AnimatableValue last = values.last;
      for (var i = 0; i < iterations; i += 1) {
        final AnimatableValue? accumulated = value.add(last);
        if (accumulated == null) {
          break;
        }
        value = accumulated;
      }
    }
    return value;
  }

  AnimatableValue _interpolate(double fraction) {
    if (values.length == 1) {
      return values.first;
    }
    final double clamped = fraction.clamp(0.0, 1.0);
    var index = 0;
    while (index < keyTimes.length - 2 && clamped >= keyTimes[index + 1]) {
      index += 1;
    }
    if (calcMode == SvgCalcMode.discrete) {
      // Discrete values each occupy the span up to the next key time, including
      // the last one, which runs to the end of the iteration.
      var step = 0;
      while (step < keyTimes.length - 1 && clamped >= keyTimes[step + 1]) {
        step += 1;
      }
      return values[step];
    }

    final double start = keyTimes[index];
    final double end = keyTimes[index + 1];
    final double span = end - start;
    double t = span <= 0 ? 1.0 : ((clamped - start) / span).clamp(0.0, 1.0);
    if (calcMode == SvgCalcMode.spline) {
      t = keySplines![index].transform(t);
    }
    return values[index].lerp(values[index + 1], t) ??
        (t < 1.0 ? values[index] : values[index + 1]);
  }
}

/// Redistributes [keyTimes] so that the value changes at a constant rate, as
/// required by `calcMode="paced"`.
///
/// Returns null when the values do not define a distance, in which case the
/// caller keeps evenly spaced key times.
List<double>? pacedKeyTimes(List<AnimatableValue> values) {
  if (values.length < 2) {
    return null;
  }
  final distances = <double>[];
  var total = 0.0;
  for (var i = 0; i < values.length - 1; i += 1) {
    final double? distance = values[i].distanceTo(values[i + 1]);
    if (distance == null) {
      return null;
    }
    distances.add(distance);
    total += distance;
  }
  if (total <= 0) {
    return null;
  }
  final keyTimes = <double>[0.0];
  var running = 0.0;
  for (final distance in distances) {
    running += distance;
    keyTimes.add(running / total);
  }
  keyTimes[keyTimes.length - 1] = 1.0;
  return keyTimes;
}

/// Key times for [count] values shown one after another, each for an equal
/// share of the iteration, as `calcMode="discrete"` requires.
List<double> discreteKeyTimes(int count) {
  if (count <= 1) {
    return <double>[0.0];
  }
  return <double>[for (var i = 0; i < count; i += 1) i / count];
}

/// Evenly spaced key times for [count] values.
List<double> evenKeyTimes(int count) {
  if (count <= 1) {
    return <double>[0.0];
  }
  return <double>[for (var i = 0; i < count; i += 1) i / (count - 1)];
}
