import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/src/animation/document.dart';

import 'document_test.dart' show attributeAt, rotationAt, svgWith;

void main() {
  group('CSS motion path', () {
    test('moves an element along its offset-path', () {
      final AnimatedSvgDocument document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a {
              offset-path: path('M0 0 L100 0');
              offset-rotate: 0deg;
              animation: travel 4s linear infinite;
            }
            @keyframes travel {
              from { offset-distance: 0% }
              to { offset-distance: 100% }
            }
          </style>
          <rect id="a" width="4" height="4"/>
        '''),
      );
      expect(document.duration, const Duration(seconds: 4));
      expect(attributeAt(document, Duration.zero, 'a', 'transform'), 'translate(0 0)');
      expect(
        attributeAt(document, const Duration(seconds: 1), 'a', 'transform'),
        'translate(25 0)',
      );
      expect(
        attributeAt(document, const Duration(seconds: 3), 'a', 'transform'),
        'translate(75 0)',
      );
    });

    test('turns the short way where the heading wraps', () {
      // The same seam as `<animateMotion>`, reached through the other call site.
      // A closed path winds a whole turn, so its heading must cross 180 degrees
      // somewhere, and `atan2` answers in (-180, 180]; without whole turns being
      // added the element spins almost the entire way round in one keyframe
      // interval. Fixing one emit site and not the other would leave this one
      // broken and nothing would say so.
      final AnimatedSvgDocument document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a {
              offset-path: path('M8 24 C8 10 40 10 40 24 C40 38 8 38 8 24 Z');
              offset-rotate: auto;
              animation: travel 3s linear infinite;
            }
            @keyframes travel {
              from { offset-distance: 0% }
              to { offset-distance: 100% }
            }
          </style>
          <polygon id="a" points="-5,-4 6,0 -5,4"/>
        '''),
      );

      final rotations = <double>[
        for (var ms = 0; ms < 3000; ms += 20) rotationAt(document, Duration(milliseconds: ms), 'a'),
      ];

      for (var i = 1; i < rotations.length; i += 1) {
        expect(
          (rotations[i] - rotations[i - 1]).abs(),
          lessThan(20),
          reason:
              'the heading jumped from '
              '${rotations[i - 1].toStringAsFixed(2)} to ${rotations[i].toStringAsFixed(2)}',
        );
      }
      expect(
        rotations.last - rotations.first,
        closeTo(360, 40),
        reason: 'one lap of a closed path is one turn, not zero and not two',
      );
    });

    test('turns to follow the path when offset-rotate is auto', () {
      final AnimatedSvgDocument document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a {
              offset-path: path('M0 0 L100 0 L100 100');
              animation: travel 4s linear infinite;
            }
            @keyframes travel {
              from { offset-distance: 0% }
              to { offset-distance: 100% }
            }
          </style>
          <rect id="a" width="4" height="4"/>
        '''),
      );
      // `auto` is the initial value, so the heading is written even where it is
      // zero, which keeps every keyframe interpolable.
      expect(
        attributeAt(document, const Duration(seconds: 1), 'a', 'transform'),
        'translate(50 0) rotate(0)',
      );
      expect(
        attributeAt(document, const Duration(seconds: 3), 'a', 'transform'),
        'translate(100 50) rotate(90)',
      );
    });

    test('adds a fixed angle to the heading', () {
      final AnimatedSvgDocument document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a {
              offset-path: path('M0 0 L100 0');
              offset-rotate: auto 90deg;
              animation: travel 4s linear infinite;
            }
            @keyframes travel {
              from { offset-distance: 0% }
              to { offset-distance: 100% }
            }
          </style>
          <rect id="a" width="4" height="4"/>
        '''),
      );
      expect(
        attributeAt(document, const Duration(seconds: 1), 'a', 'transform'),
        'translate(25 0) rotate(90)',
      );
    });

    for (final (String rotate, String expected) in [
      ('auto', '0'),
      ('auto 90deg', '90'),
      ('auto -30deg', '-30'),
      ('reverse', '180'),
      ('reverse 30deg', '210'),
      ('reverse -30deg', '150'),
      ('30deg', '30'),
      ('-30deg', '-30'),
    ]) {
      test('reads offset-rotate: $rotate', () {
        final AnimatedSvgDocument document = AnimatedSvgDocument.parse(
          svgWith('''
            <style>
              #a {
                offset-path: path('M0 0 L100 0');
                offset-rotate: $rotate;
                animation: travel 4s linear infinite;
              }
              @keyframes travel {
                from { offset-distance: 0% }
                to { offset-distance: 100% }
              }
            </style>
            <rect id="a" width="4" height="4"/>
          '''),
        );
        expect(
          attributeAt(document, const Duration(seconds: 1), 'a', 'transform'),
          'translate(25 0) rotate($expected)',
        );
      });
    }

    test('wraps around a transform the element already has', () {
      final AnimatedSvgDocument document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a {
              offset-path: path('M0 0 L100 0');
              offset-rotate: 0deg;
              animation: travel 4s linear infinite;
            }
            @keyframes travel {
              from { offset-distance: 0% }
              to { offset-distance: 100% }
            }
          </style>
          <rect id="a" transform="scale(2)" width="4" height="4"/>
        '''),
      );
      expect(
        attributeAt(document, const Duration(seconds: 1), 'a', 'transform'),
        'translate(25 0) scale(2)',
      );
    });

    test('places an element that sits at a fixed point on its path', () {
      final AnimatedSvgDocument document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a {
              offset-path: path('M0 0 L100 0');
              offset-distance: 40%;
              offset-rotate: 0deg;
            }
          </style>
          <rect id="a" transform="scale(2)" width="4" height="4"/>
        '''),
      );
      expect(document.isAnimated, isFalse);
      expect(attributeAt(document, Duration.zero, 'a', 'transform'), 'translate(40 0) scale(2)');
    });

    test('resolves a distance given in user units', () {
      final AnimatedSvgDocument document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a {
              offset-path: path('M0 0 L100 0');
              offset-distance: 25;
              offset-rotate: 0deg;
            }
          </style>
          <rect id="a" width="4" height="4"/>
        '''),
      );
      expect(attributeAt(document, Duration.zero, 'a', 'transform'), 'translate(25 0)');
    });

    test('ignores offset-path shapes that are not a path', () {
      final AnimatedSvgDocument document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a { offset-path: ray(45deg closest-side); offset-distance: 50% }
          </style>
          <rect id="a" width="4" height="4"/>
        '''),
      );
      expect(attributeAt(document, Duration.zero, 'a', 'transform'), isNull);
    });

    test('never writes the offset properties back as attributes', () {
      final AnimatedSvgDocument document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a { offset-path: path('M0 0 L100 0'); offset-distance: 50% }
          </style>
          <rect id="a" width="4" height="4"/>
        '''),
      );
      final String frame = document.sampleAt(Duration.zero);
      expect(frame, isNot(contains('offset-path')));
      expect(frame, isNot(contains('offset-distance')));
      expect(frame, isNot(contains('offset-rotate')));
    });
  });
}
