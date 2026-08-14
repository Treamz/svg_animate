import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

/// How the values of an animation are distributed across its duration.
///
/// See https://www.w3.org/TR/SVG11/animate.html#CalcModeAttribute.
enum SvgCalcMode {
  /// The value jumps from one keyframe to the next with no interpolation.
  discrete,

  /// Values are interpolated evenly between keyframes.
  linear,

  /// Values are interpolated so that the rate of change is constant, ignoring
  /// any declared key times.
  paced,

  /// Values are interpolated with a cubic bezier defined by `keySplines`.
  spline,
}

/// What an animation does to its target once its active duration has ended.
///
/// See https://www.w3.org/TR/SVG11/animate.html#FillAttribute.
enum SvgFillMode {
  /// The target reverts to its underlying value.
  remove,

  /// The target keeps the last value the animation produced.
  freeze,
}

/// The direction in which each iteration of a CSS animation runs.
///
/// See https://drafts.csswg.org/css-animations/#animation-direction.
enum SvgAnimationDirection {
  /// Every iteration runs forwards.
  normal,

  /// Every iteration runs backwards.
  reverse,

  /// Even iterations run forwards, odd iterations run backwards.
  alternate,

  /// Even iterations run backwards, odd iterations run forwards.
  alternateReverse,
}

/// A curve that holds its value for a number of equal length steps.
///
/// Implements the CSS `steps()` timing function and SMIL's
/// `calcMode="discrete"` behavior.
class StepsCurve extends Curve {
  /// Creates a curve with [stepCount] steps.
  ///
  /// If [jumpAtStart] is true the first step happens immediately, matching
  /// `steps(n, start)`; otherwise the last step happens at the end, matching
  /// `steps(n, end)`.
  const StepsCurve(this.stepCount, {this.jumpAtStart = false}) : assert(stepCount > 0);

  /// The number of equal length steps.
  final int stepCount;

  /// Whether the value jumps at the start of each step rather than its end.
  final bool jumpAtStart;

  // [Curve.transform] returns the endpoints unchanged, but a step function that
  // jumps at the start has already left 0.0 behind by the time it is sampled
  // there, so the step has to be evaluated for every input.
  @override
  double transform(double t) {
    assert(t >= 0.0 && t <= 1.0);
    return transformInternal(t);
  }

  @override
  double transformInternal(double t) {
    final int step = jumpAtStart ? (t * stepCount).floor() + 1 : (t * stepCount).floor();
    return (step / stepCount).clamp(0.0, 1.0);
  }

  @override
  String toString() => 'StepsCurve($stepCount, jumpAtStart: $jumpAtStart)';
}

final RegExp _clockUnitPattern = RegExp(r'^([+-]?[0-9]*\.?[0-9]+)(h|min|ms|s)?$');

/// Parses a SMIL clock value or a CSS time.
///
/// Accepts full and partial clock values (`01:02:03.5`, `02:30`) as well as
/// timecount values with an optional `h`, `min`, `s`, or `ms` unit. Returns
/// null if [raw] is not a valid clock value, including for the `indefinite`
/// keyword, which callers handle separately.
Duration? parseClockValue(String raw) {
  final String value = raw.trim();
  if (value.isEmpty) {
    return null;
  }
  if (value.contains(':')) {
    final List<String> parts = value.split(':');
    if (parts.length > 3) {
      return null;
    }
    var seconds = 0.0;
    for (final part in parts) {
      final double? component = double.tryParse(part);
      if (component == null) {
        return null;
      }
      seconds = seconds * 60 + component;
    }
    return _secondsToDuration(seconds);
  }
  final RegExpMatch? match = _clockUnitPattern.firstMatch(value);
  if (match == null) {
    return null;
  }
  final double? amount = double.tryParse(match.group(1)!);
  if (amount == null) {
    return null;
  }
  switch (match.group(2)) {
    case 'h':
      return _secondsToDuration(amount * 3600);
    case 'min':
      return _secondsToDuration(amount * 60);
    case 'ms':
      return _secondsToDuration(amount / 1000);
    case 's':
    case null:
    default:
      return _secondsToDuration(amount);
  }
}

Duration _secondsToDuration(double seconds) =>
    Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());

/// Parses a `keySplines` control point quadruple into a [Cubic] curve.
///
/// Returns null if [raw] does not hold four numbers in the range 0.0 to 1.0 for
/// the x coordinates, as required by the specification.
Curve? parseKeySpline(String raw) {
  final List<double?> points = raw
      .trim()
      .split(RegExp(r'[\s,]+'))
      .where((String part) => part.isNotEmpty)
      .map(double.tryParse)
      .toList();
  if (points.length != 4 || points.contains(null)) {
    return null;
  }
  final double x1 = points[0]!;
  final double y1 = points[1]!;
  final double x2 = points[2]!;
  final double y2 = points[3]!;
  if (x1 < 0 || x1 > 1 || x2 < 0 || x2 > 1) {
    return null;
  }
  return Cubic(x1, y1, x2, y2);
}

/// Parses a CSS `animation-timing-function` value.
///
/// Returns [Curves.linear] for values that cannot be understood, matching the
/// permissive behavior of SVG renderers.
Curve parseCssTimingFunction(String raw) {
  final String value = raw.trim().toLowerCase();
  switch (value) {
    case 'linear':
      return Curves.linear;
    case 'ease':
      return const Cubic(0.25, 0.1, 0.25, 1.0);
    case 'ease-in':
      return const Cubic(0.42, 0.0, 1.0, 1.0);
    case 'ease-out':
      return const Cubic(0.0, 0.0, 0.58, 1.0);
    case 'ease-in-out':
      return const Cubic(0.42, 0.0, 0.58, 1.0);
    case 'step-start':
      return const StepsCurve(1, jumpAtStart: true);
    case 'step-end':
      return const StepsCurve(1);
  }
  if (value.startsWith('cubic-bezier(') && value.endsWith(')')) {
    return parseKeySpline(value.substring('cubic-bezier('.length, value.length - 1)) ??
        Curves.linear;
  }
  if (value.startsWith('steps(') && value.endsWith(')')) {
    final List<String> arguments = value
        .substring('steps('.length, value.length - 1)
        .split(',')
        .map((String argument) => argument.trim())
        .toList();
    final int? stepCount = arguments.isEmpty ? null : int.tryParse(arguments.first);
    if (stepCount == null || stepCount <= 0) {
      return Curves.linear;
    }
    final bool jumpAtStart =
        arguments.length > 1 && (arguments[1] == 'start' || arguments[1] == 'jump-start');
    return StepsCurve(stepCount, jumpAtStart: jumpAtStart);
  }
  return Curves.linear;
}

/// The timing of a single animation: when it starts, how long one iteration
/// lasts, how often it repeats, and what it leaves behind.
@immutable
class SvgAnimationTiming {
  /// Creates timing for an animation.
  const SvgAnimationTiming({
    this.begin = Duration.zero,
    this.simpleDuration,
    this.repeatCount,
    this.end,
    this.fill = SvgFillMode.remove,
    this.direction = SvgAnimationDirection.normal,
  });

  /// The offset from the start of the document at which this animation begins.
  final Duration begin;

  /// How long a single iteration lasts, or null when the duration is
  /// indefinite, in which case the animation holds its first value.
  final Duration? simpleDuration;

  /// How many times the animation repeats, or null when it repeats
  /// indefinitely.
  ///
  /// May be fractional, as `repeatCount="2.5"` is legal.
  final double? repeatCount;

  /// An explicit end time for the active interval, if one was given.
  final Duration? end;

  /// What the animation leaves behind once its active interval is over.
  final SvgFillMode fill;

  /// The direction in which successive iterations run.
  ///
  /// Always [SvgAnimationDirection.normal] for SMIL animations, which have no
  /// equivalent of the CSS `animation-direction` property.
  final SvgAnimationDirection direction;

  /// Whether this animation never stops repeating.
  bool get repeatsIndefinitely => repeatCount == null;

  /// How long the animation is active for, or null if it never ends.
  Duration? get activeDuration {
    final Duration? fromRepeats = switch ((simpleDuration, repeatCount)) {
      (final Duration duration, final double count) => duration * count,
      _ => null,
    };
    final Duration? fromEnd = end == null ? null : end! - begin;
    if (fromRepeats == null) {
      return fromEnd;
    }
    if (fromEnd == null) {
      return fromRepeats;
    }
    return fromRepeats < fromEnd ? fromRepeats : fromEnd;
  }

  /// The time at which the animation stops changing its target, or null if it
  /// never stops.
  ///
  /// Used to work out how long the whole document takes.
  Duration? get activeEnd {
    final Duration? duration = activeDuration;
    return duration == null ? null : begin + duration;
  }

  @override
  bool operator ==(Object other) =>
      other is SvgAnimationTiming &&
      other.begin == begin &&
      other.simpleDuration == simpleDuration &&
      other.repeatCount == repeatCount &&
      other.end == end &&
      other.fill == fill &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(begin, simpleDuration, repeatCount, end, fill, direction);
}

/// The position of an animation at a point in time.
@immutable
class SvgAnimationSample {
  /// Creates a sample at [fraction] of iteration [iteration].
  const SvgAnimationSample(this.fraction, this.iteration);

  /// How far through a single iteration the animation is, from 0.0 to 1.0.
  final double fraction;

  /// The zero based index of the iteration this sample falls in.
  ///
  /// Used by `accumulate="sum"`.
  final int iteration;
}

/// Works out where [timing] is at [time], measured from the start of the
/// document.
///
/// Returns null when the animation is not contributing a value at [time],
/// either because it has not begun or because it has ended and does not freeze.
SvgAnimationSample? sampleTiming(SvgAnimationTiming timing, Duration time) {
  if (time < timing.begin) {
    return null;
  }
  final Duration simpleDuration = timing.simpleDuration ?? Duration.zero;
  if (simpleDuration <= Duration.zero) {
    // A zero or indefinite simple duration means the animation holds its first
    // value for as long as it is active.
    return const SvgAnimationSample(0, 0);
  }

  Duration localTime = time - timing.begin;
  final Duration? activeDuration = timing.activeDuration;
  if (activeDuration != null && localTime >= activeDuration) {
    if (timing.fill == SvgFillMode.remove) {
      return null;
    }
    // Freeze on the final value the animation produced.
    localTime = activeDuration;
  }

  final double progress = localTime.inMicroseconds / simpleDuration.inMicroseconds;
  int iteration = progress.floor();
  double fraction = progress - iteration;
  if (fraction == 0 && iteration > 0) {
    // The end of an iteration is only the start of the next one while the
    // animation is still running; a frozen animation stays at the end.
    final bool atActiveEnd = activeDuration != null && localTime >= activeDuration;
    if (atActiveEnd) {
      iteration -= 1;
      fraction = 1;
    }
  }
  return SvgAnimationSample(_applyDirection(timing.direction, fraction, iteration), iteration);
}

double _applyDirection(SvgAnimationDirection direction, double fraction, int iteration) {
  switch (direction) {
    case SvgAnimationDirection.normal:
      return fraction;
    case SvgAnimationDirection.reverse:
      return 1.0 - fraction;
    case SvgAnimationDirection.alternate:
      return iteration.isEven ? fraction : 1.0 - fraction;
    case SvgAnimationDirection.alternateReverse:
      return iteration.isEven ? 1.0 - fraction : fraction;
  }
}
