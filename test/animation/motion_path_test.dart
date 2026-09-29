import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/src/animation/motion_path.dart';

/// The track the example's orbit sample follows: two cubics that meet at both
/// ends, closed with a `Z` that therefore has nowhere to go.
const String closedTrack = 'M8 24 C8 10 40 10 40 24 C40 38 8 38 8 24 Z';

void main() {
  group('ContinuousHeading', () {
    test('adds a whole turn rather than letting a heading wrap', () {
      // The four headings either side of the seam on the orbit track. `atan2`
      // answers in (-180, 180], so the third one arrives as its own value minus
      // a turn, and the step between the second and third reads as -355.8.
      final heading = ContinuousHeading();
      final List<double> out = <double>[
        for (final double degrees in <double>[173.66, 177.91, -177.91, -173.66])
          heading.next(degrees),
      ];

      expect(out[0], closeTo(173.66, 0.001));
      expect(out[1], closeTo(177.91, 0.001));
      expect(out[2], closeTo(182.09, 0.001), reason: 'the same direction, a turn further on');
      expect(out[3], closeTo(186.34, 0.001));
      for (var i = 1; i < out.length; i += 1) {
        expect((out[i] - out[i - 1]).abs(), lessThan(10));
      }
    });

    test('leaves a run that never wraps exactly as it was', () {
      final heading = ContinuousHeading();
      for (final double degrees in <double>[-90, -45, 0, 45, 90]) {
        expect(heading.next(degrees), degrees);
      }
    });

    test('a reversal turns one way rather than both', () {
      // Half a turn is genuinely ambiguous: -180 and +180 are the same
      // direction and equally far away. `roundToDouble` rounds half away from
      // zero, so this is what the arithmetic picks. Pinned so that changing the
      // formula is a decision rather than a surprise.
      final heading = ContinuousHeading();

      expect(heading.next(0), 0);
      expect(heading.next(180), -180);
    });

    test('carries on through more than one turn', () {
      // Two laps of a circle. Nothing here should be folded back: the second
      // lap ends two turns from where the first began.
      final heading = ContinuousHeading();
      double last = 0;
      for (var lap = 0; lap < 2; lap += 1) {
        for (var degrees = -180.0; degrees < 180; degrees += 30) {
          last = heading.next(degrees);
        }
      }
      expect(last, closeTo(150 + 360, 0.001));
    });
  });

  group('MotionPath', () {
    test('a closed path comes back to where it started, still heading up', () {
      // Not a given: the trailing `Z` adds a segment from the end point to the
      // start point, which for this track is the same point, so it has no
      // direction of its own to offer and must not be the one reported.
      final MotionPath path = MotionPath.parse(closedTrack)!;

      final MotionPathSample start = path.sampleAtFraction(0);
      final MotionPathSample end = path.sampleAtFraction(1);

      expect(end.x, closeTo(start.x, 0.001));
      expect(end.y, closeTo(start.y, 0.001));

      // Both point up the left side, and they are not identical: the heading is
      // the direction of a flattened chord, so arriving reads -95.52 and leaving
      // reads -84.48, either side of the -90 the real tangent has. What matters
      // is that the two are a few degrees apart rather than a turn apart.
      expect(end.angleInDegrees, closeTo(-95.52, 0.01));
      expect(start.angleInDegrees, closeTo(-84.48, 0.01));
      expect((end.angleInDegrees - start.angleInDegrees).abs(), lessThan(20));
    });

    test('takes the heading from a chord that has one', () {
      // The first segment here has no length, and `atan2(0, 0)` is zero, which
      // would point a tracking element right rather than along the path.
      final MotionPath path = MotionPath.parse('M0 0 L0 0 L10 10')!;

      expect(path.sampleAtFraction(0).angleInDegrees, closeTo(45, 0.001));
    });

    test('does not take a heading from the move between subpaths', () {
      // The move covers ground without drawing, so it has a direction and that
      // direction is not travel. Pinned because it is a decision: this used to
      // report 90, the direction of the jump from (0,0) to (0,10).
      final MotionPath path = MotionPath.parse('M0 0 M0 10 L10 10')!;

      expect(path.sampleAtFraction(0).angleInDegrees, 0);
    });

    test('survives a path that is only a point', () {
      final MotionPath? path = MotionPath.parse('M8 24 Z');

      expect(path, isNotNull);
      expect(path!.length, 0);
      final MotionPathSample sample = path.sampleAtFraction(0.5);
      expect(sample.x, 8);
      expect(sample.y, 24);
      expect(sample.angleInDegrees, 0, reason: 'there is no direction to be had');
    });
  });
}
