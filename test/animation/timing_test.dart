import 'package:flutter/animation.dart';
import 'package:svg_animate/src/animation/timing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseClockValue', () {
    test('parses timecount values', () {
      expect(parseClockValue('2'), const Duration(seconds: 2));
      expect(parseClockValue('2s'), const Duration(seconds: 2));
      expect(parseClockValue('1.5s'), const Duration(milliseconds: 1500));
      expect(parseClockValue('250ms'), const Duration(milliseconds: 250));
      expect(parseClockValue('2min'), const Duration(minutes: 2));
      expect(parseClockValue('1h'), const Duration(hours: 1));
    });

    test('parses full and partial clock values', () {
      expect(parseClockValue('02:30'), const Duration(minutes: 2, seconds: 30));
      expect(
        parseClockValue('01:02:03.5'),
        const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 500),
      );
    });

    test('rejects keywords and nonsense', () {
      expect(parseClockValue('indefinite'), isNull);
      expect(parseClockValue('click'), isNull);
      expect(parseClockValue('rect1.end'), isNull);
      expect(parseClockValue(''), isNull);
    });
  });

  group('parseKeySpline', () {
    test('builds a cubic from four control points', () {
      final Curve? curve = parseKeySpline('0 0 1 1');
      expect(curve, isA<Cubic>());
      expect(curve!.transform(0.5), closeTo(0.5, 0.01));
    });

    test('rejects malformed splines', () {
      expect(parseKeySpline('0 0 1'), isNull);
      expect(parseKeySpline('0 0 2 1'), isNull, reason: 'x must be within 0..1');
    });
  });

  group('parseCssTimingFunction', () {
    test('understands the keywords, cubic-bezier, and steps', () {
      expect(parseCssTimingFunction('linear'), Curves.linear);
      expect(parseCssTimingFunction('ease-in'), isA<Cubic>());
      expect(parseCssTimingFunction('cubic-bezier(0.1, 0.2, 0.3, 0.4)'), isA<Cubic>());
      expect(parseCssTimingFunction('steps(4, end)'), isA<StepsCurve>());
    });

    test('falls back to linear for anything unrecognized', () {
      expect(parseCssTimingFunction('wobble'), Curves.linear);
      expect(parseCssTimingFunction('steps(0)'), Curves.linear);
    });
  });

  group('StepsCurve', () {
    test('holds each step until its end', () {
      const curve = StepsCurve(4);
      expect(curve.transform(0), 0);
      expect(curve.transform(0.2), 0);
      expect(curve.transform(0.3), 0.25);
      expect(curve.transform(1), 1);
    });

    test('jumps at the start when asked to', () {
      const curve = StepsCurve(4, jumpAtStart: true);
      expect(curve.transform(0), 0.25);
      expect(curve.transform(1), 1);
    });
  });

  group('sampleTiming', () {
    const oneSecond = SvgAnimationTiming(simpleDuration: Duration(seconds: 1), repeatCount: 1);

    test('does not contribute before it begins', () {
      const delayed = SvgAnimationTiming(
        begin: Duration(seconds: 1),
        simpleDuration: Duration(seconds: 1),
        repeatCount: 1,
      );
      expect(sampleTiming(delayed, const Duration(milliseconds: 999)), isNull);
      expect(sampleTiming(delayed, const Duration(seconds: 1))!.fraction, 0);
    });

    test('reports the fraction through the current iteration', () {
      expect(sampleTiming(oneSecond, Duration.zero)!.fraction, 0);
      expect(sampleTiming(oneSecond, const Duration(milliseconds: 250))!.fraction, 0.25);
    });

    test('is removed after its active duration by default', () {
      expect(sampleTiming(oneSecond, const Duration(seconds: 2)), isNull);
    });

    test('freezes on the final value when asked to', () {
      const frozen = SvgAnimationTiming(
        simpleDuration: Duration(seconds: 1),
        repeatCount: 1,
        fill: SvgFillMode.freeze,
      );
      final SvgAnimationSample sample = sampleTiming(frozen, const Duration(seconds: 5))!;
      expect(sample.fraction, 1);
      expect(sample.iteration, 0);
    });

    test('counts iterations when repeating', () {
      const repeating = SvgAnimationTiming(simpleDuration: Duration(seconds: 1));
      expect(repeating.repeatsIndefinitely, isTrue);
      final SvgAnimationSample sample = sampleTiming(
        repeating,
        const Duration(milliseconds: 2500),
      )!;
      expect(sample.iteration, 2);
      expect(sample.fraction, closeTo(0.5, 1e-9));
    });

    test('honors a repeat count with a fractional part', () {
      const timing = SvgAnimationTiming(
        simpleDuration: Duration(seconds: 1),
        repeatCount: 2.5,
        fill: SvgFillMode.freeze,
      );
      expect(timing.activeEnd, const Duration(milliseconds: 2500));
      expect(sampleTiming(timing, const Duration(seconds: 10))!.fraction, closeTo(0.5, 1e-9));
    });

    test('reverses and alternates according to the CSS direction', () {
      const reverse = SvgAnimationTiming(
        simpleDuration: Duration(seconds: 1),
        direction: SvgAnimationDirection.reverse,
      );
      expect(sampleTiming(reverse, const Duration(milliseconds: 250))!.fraction, 0.75);

      const alternate = SvgAnimationTiming(
        simpleDuration: Duration(seconds: 1),
        direction: SvgAnimationDirection.alternate,
      );
      expect(sampleTiming(alternate, const Duration(milliseconds: 250))!.fraction, 0.25);
      expect(sampleTiming(alternate, const Duration(milliseconds: 1250))!.fraction, 0.75);
    });

    test('holds the first value when the duration is indefinite', () {
      const indefinite = SvgAnimationTiming();
      expect(sampleTiming(indefinite, const Duration(seconds: 10))!.fraction, 0);
    });
  });
}
