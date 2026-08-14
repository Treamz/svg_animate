import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/src/animation/document.dart';

import 'document_test.dart' show attributeAt, svgWith;

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
