import 'package:svg_animate/src/animation/document.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

/// Wraps [body] in an SVG root element with a 100x100 view box.
String svgWith(String body) =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">$body</svg>';

/// The angle of the `rotate(...)` in the transform of [id] at [time].
double rotationAt(AnimatedSvgDocument document, Duration time, String id) {
  final String? transform = attributeAt(document, time, id, 'transform');
  final RegExpMatch? match = RegExp(r'rotate\(([-0-9.eE]+)').firstMatch(transform ?? '');
  if (match == null) {
    fail('No rotation in "$transform" at $time.');
  }
  return double.parse(match.group(1)!);
}

/// The value of [attribute] on the element with the id [id], in the frame of
/// [document] at [time].
String? attributeAt(AnimatedSvgDocument document, Duration time, String id, String attribute) {
  final frame = XmlDocument.parse(document.sampleAt(time));
  for (final XmlElement element in frame.descendantElements) {
    if (element.getAttribute('id') == id) {
      return element.getAttribute(attribute);
    }
  }
  fail('No element with id "$id" in the sampled frame.');
}

void main() {
  group('static documents', () {
    test('an SVG with no animation has no duration', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('<rect id="a" width="10" height="10" fill="red"/>'),
      );
      expect(document.isAnimated, isFalse);
      expect(document.duration, Duration.zero);
      expect(attributeAt(document, Duration.zero, 'a', 'fill'), 'red');
    });

    test('rejects markup that is not well formed', () {
      expect(() => AnimatedSvgDocument.parse('<svg><rect></svg>'), throwsA(isA<XmlException>()));
    });
  });

  group('<animate>', () {
    test('with keyTimes that do not fit its values does not run, as in Chrome', () {
      // Out of order, too few, not starting at 0, and blending values that do
      // not end at 1: SMIL puts each animation in error, and Chrome leaves x
      // at 5 for all four.
      final document = AnimatedSvgDocument.parse(
        svgWith(
          '''
<rect id="a" x="5" width="10" height="10"><animate attributeName="x" values="0;10;20" keyTimes="0;0.8;0.3" dur="1s"/></rect>
<rect id="b" x="5" width="10" height="10"><animate attributeName="x" values="0;10;20" keyTimes="0;0.5" dur="1s"/></rect>
<rect id="c" x="5" width="10" height="10"><animate attributeName="x" values="0;10;20" keyTimes="0.1;0.5;1" dur="1s"/></rect>
<rect id="d" x="5" width="10" height="10"><animate attributeName="x" values="0;10;20" keyTimes="0;0.5;0.9" dur="1s"/></rect>''',
        ),
      );
      const time = Duration(milliseconds: 600);

      for (final String id in <String>['a', 'b', 'c', 'd']) {
        expect(attributeAt(document, time, id, 'x'), '5', reason: id);
      }
    });

    test('with discrete keyTimes that stop short of 1 still runs', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
<rect id="r" x="5" width="10" height="10">
  <animate attributeName="x" values="0;10" keyTimes="0;0.5" calcMode="discrete" dur="1s"/>
</rect>'''),
      );

      expect(attributeAt(document, const Duration(milliseconds: 600), 'r', 'x'), '10');
    });

    test('without from starts an attribute the element does not set at its initial value', () {
      // What Chrome draws for each: r, width and x start at 0, opacity at 1.
      final document = AnimatedSvgDocument.parse(
        svgWith('''
<circle id="c" cx="50" cy="50"><animate attributeName="r" to="4" dur="1s"/></circle>
<rect id="w" height="10"><animate attributeName="width" to="20" dur="1s"/></rect>
<rect id="x" width="10" height="10"><animate attributeName="x" to="20" dur="1s"/></rect>
<rect id="o" width="10" height="10"><animate attributeName="opacity" to="0" dur="1s"/></rect>'''),
      );
      const half = Duration(milliseconds: 500);

      expect(attributeAt(document, half, 'c', 'r'), '2');
      expect(attributeAt(document, half, 'w', 'width'), '10');
      expect(attributeAt(document, half, 'x', 'x'), '10');
      expect(attributeAt(document, half, 'o', 'opacity'), '0.5');
    });

    test('without from still starts from the attribute when the element sets it', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('<circle id="c" r="2"><animate attributeName="r" to="4" dur="1s"/></circle>'),
      );

      expect(attributeAt(document, const Duration(milliseconds: 500), 'c', 'r'), '3');
    });

    test('without from starts an inherited property from the parent that sets it', () {
      // The path has no stroke-width of its own; the group's is what it draws
      // with, so that is where a "to" animation starts.
      final document = AnimatedSvgDocument.parse(
        svgWith('''
<g stroke-width="2"><path id="p" d="M0 0 H10" stroke="#000">
  <animate attributeName="stroke-width" to="6" dur="1s"/>
</path></g>'''),
      );

      expect(attributeAt(document, const Duration(milliseconds: 500), 'p', 'stroke-width'), '4');
    });

    test('interpolates between from and to', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" width="10" height="10" opacity="1">
            <animate attributeName="opacity" from="0" to="1" dur="2s"
                repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(document.duration, const Duration(seconds: 2));
      expect(document.loops, isTrue);
      expect(attributeAt(document, Duration.zero, 'a', 'opacity'), '0');
      expect(attributeAt(document, const Duration(seconds: 1), 'a', 'opacity'), '0.5');
    });

    test('removes the animation elements from the compiled markup', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" width="10" height="10">
            <animate attributeName="opacity" from="0" to="1" dur="2s"/>
          </rect>
        '''),
      );
      expect(document.sampleAt(Duration.zero), isNot(contains('<animate')));
    });

    test('walks a values list using key times', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <circle id="a" r="1">
            <animate attributeName="r" values="0;10;0" keyTimes="0;0.25;1" dur="4s"
                repeatCount="indefinite"/>
          </circle>
        '''),
      );
      expect(attributeAt(document, Duration.zero, 'a', 'r'), '0');
      expect(attributeAt(document, const Duration(seconds: 1), 'a', 'r'), '10');
      expect(attributeAt(document, const Duration(seconds: 2), 'a', 'r'), '6.666667');
    });

    test('interpolates colors', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" fill="black">
            <animate attributeName="fill" from="black" to="white" dur="2s"
                repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(attributeAt(document, const Duration(seconds: 1), 'a', 'fill'), '#808080');
    });

    test('uses the base value when only "to" is given', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" x="10">
            <animate attributeName="x" to="20" dur="2s" repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(attributeAt(document, const Duration(seconds: 1), 'a', 'x'), '15');
    });

    test('adds "by" to the base value', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" x="10">
            <animate attributeName="x" by="10" dur="2s" repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(attributeAt(document, const Duration(seconds: 1), 'a', 'x'), '15');
    });

    test('steps between values when calcMode is discrete', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" fill="red">
            <animate attributeName="fill" values="red;lime" calcMode="discrete" dur="2s"
                repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(attributeAt(document, Duration.zero, 'a', 'fill'), '#ff0000');
      expect(attributeAt(document, const Duration(milliseconds: 1500), 'a', 'fill'), '#00ff00');
    });

    test('restores the base value once a non-freezing animation ends', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" opacity="0.25" width="10" height="10">
            <animate attributeName="opacity" from="0" to="1" dur="1s"/>
            <animate attributeName="width" from="0" to="50" dur="2s"
                repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(attributeAt(document, const Duration(milliseconds: 1500), 'a', 'opacity'), '0.25');
    });

    test('freezes on its final value when asked to', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" opacity="0.25" width="10" height="10">
            <animate attributeName="opacity" from="0" to="1" dur="1s" fill="freeze"/>
            <animate attributeName="width" from="0" to="50" dur="2s"
                repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(attributeAt(document, const Duration(milliseconds: 1500), 'a', 'opacity'), '1');
    });

    test('waits for its begin offset', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" opacity="1">
            <animate attributeName="opacity" from="0" to="1" begin="1s" dur="2s"
                repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(attributeAt(document, Duration.zero, 'a', 'opacity'), '1');
      expect(attributeAt(document, const Duration(seconds: 2), 'a', 'opacity'), '0.5');
    });

    test('ignores animations that wait for an event', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" opacity="1">
            <animate attributeName="opacity" from="0" to="1" begin="click" dur="2s"/>
          </rect>
        '''),
      );
      expect(document.isAnimated, isFalse);
      expect(attributeAt(document, Duration.zero, 'a', 'opacity'), '1');
    });

    test('targets another element through href', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" opacity="1"/>
          <animate xlink:href="#a" attributeName="opacity" from="0" to="1" dur="2s"
              repeatCount="indefinite"
              xmlns:xlink="http://www.w3.org/1999/xlink"/>
        '''),
      );
      expect(attributeAt(document, const Duration(seconds: 1), 'a', 'opacity'), '0.5');
    });
  });

  group('<animateTransform>', () {
    test('turns about a transform-origin written as an attribute', () {
      // Chrome scales both rects about their middle, 15 15, with or without px.
      final document = AnimatedSvgDocument.parse(
        svgWith(
          '''
<rect id="t" x="10" y="10" width="10" height="10" transform-origin="15px 15px">
  <animateTransform attributeName="transform" type="scale" values="2" dur="1s"/>
</rect>
<rect id="u" x="10" y="10" width="10" height="10" transform-origin="15 15" transform="scale(2)"/>''',
        ),
      );
      const time = Duration(milliseconds: 500);

      expect(
        attributeAt(document, time, 't', 'transform'),
        'translate(15 15) scale(2) translate(-15 -15)',
      );
      expect(
        attributeAt(document, time, 'u', 'transform'),
        'translate(15 15) scale(2) translate(-15 -15)',
      );
    });

    test('animates a rotation about a point', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" width="10" height="10">
            <animateTransform attributeName="transform" type="rotate"
                from="0 50 50" to="360 50 50" dur="4s" repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(
        attributeAt(document, const Duration(seconds: 1), 'a', 'transform'),
        'rotate(90 50 50)',
      );
    });

    test('composes with the base transform when additive', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" transform="translate(5 5)" width="10" height="10">
            <animateTransform attributeName="transform" type="rotate" additive="sum"
                from="0" to="360" dur="4s" repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(
        attributeAt(document, const Duration(seconds: 1), 'a', 'transform'),
        'translate(5 5) rotate(90)',
      );
    });

    test('replaces the base transform by default', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" transform="translate(5 5)" width="10" height="10">
            <animateTransform attributeName="transform" type="rotate"
                from="0" to="360" dur="4s" repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(attributeAt(document, const Duration(seconds: 1), 'a', 'transform'), 'rotate(90)');
    });

    test('drops transform arguments the compiler would reject', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" width="10" height="10">
            <animateTransform attributeName="transform" type="rotate"
                from="0 50 50 0" to="360 50 50 0" dur="4s" repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(
        attributeAt(document, const Duration(seconds: 1), 'a', 'transform'),
        'rotate(90 50 50)',
      );
    });

    test('accumulates across repeats', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" width="10" height="10">
            <animateTransform attributeName="transform" type="translate"
                from="0 0" to="10 0" dur="1s" repeatCount="3" accumulate="sum"
                fill="freeze"/>
          </rect>
        '''),
      );
      expect(
        attributeAt(document, const Duration(milliseconds: 2500), 'a', 'transform'),
        'translate(25 0)',
      );
    });
  });

  group('<set>', () {
    test('switches to its value at its begin time and holds it', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" fill="red" width="10" height="10">
            <set attributeName="fill" to="blue" begin="1s"/>
            <animate attributeName="width" from="0" to="50" dur="4s"
                repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(attributeAt(document, Duration.zero, 'a', 'fill'), 'red');
      expect(attributeAt(document, const Duration(seconds: 2), 'a', 'fill'), '#0000ff');
    });
  });

  group('<animateMotion>', () {
    test('turns the short way where the heading wraps', () {
      // The example\'s orbit track. Its heading passes through exactly 180
      // degrees along the bottom, where the arrow is travelling leftwards, and
      // `atan2` answers in (-180, 180] — so two neighbouring keyframes used to
      // come out +177.91 and -177.91. Keyframes are interpolated linearly, so
      // that reads as -355.8 degrees rather than +4.2, and the arrow spun
      // almost the whole way round in 64 ms, once every loop.
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <polygon id="a" points="-5,-4 6,0 -5,4">
            <animateMotion path="M8 24 C8 10 40 10 40 24 C40 38 8 38 8 24 Z"
                dur="3s" rotate="auto" repeatCount="indefinite"/>
          </polygon>
        '''),
      );

      // 2180 ms to 2360 ms is the stretch either side of the seam.
      final rotations = <double>[
        for (var ms = 2180; ms <= 2360; ms += 20)
          rotationAt(document, Duration(milliseconds: ms), 'a'),
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
        rotations.last,
        greaterThan(rotations.first),
        reason: 'and it is still turning, rather than having been flattened',
      );
    });

    test('moves the element along its path', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" width="10" height="10">
            <animateMotion path="M0 0 L100 0" dur="4s" repeatCount="indefinite"/>
          </rect>
        '''),
      );
      final String? transform = attributeAt(document, const Duration(seconds: 2), 'a', 'transform');
      expect(transform, startsWith('translate(50'));
    });

    test('keeps moving across a corner when the heading tracks the path', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" width="4" height="4">
            <animateMotion path="M0 0 L100 0 L100 100" dur="4s" rotate="auto"
                repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(
        attributeAt(document, const Duration(milliseconds: 1000), 'a', 'transform'),
        'translate(50 0) rotate(0)',
      );
      expect(
        attributeAt(document, const Duration(milliseconds: 3000), 'a', 'transform'),
        'translate(100 50) rotate(90)',
      );

      // The corner is halfway along the path, where the heading passes through
      // zero. Every sample carries a rotation, even the ones on the horizontal
      // leg, so neighbouring keyframes stay interpolable and the motion keeps
      // advancing instead of holding one sample until the heading changes.
      final aroundCorner = <String?>[
        for (final int ms in <int>[1900, 1950, 2000, 2050, 2100])
          attributeAt(document, Duration(milliseconds: ms), 'a', 'transform'),
      ];
      expect(aroundCorner.every((String? transform) => transform!.contains('rotate(')), isTrue);
      expect(
        aroundCorner.toSet().length,
        aroundCorner.length,
        reason: 'the motion should advance on every sample, not stall at the corner',
      );
    });

    test('composes in front of the transform the element already has', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a" transform="scale(2)" width="10" height="10">
            <animateMotion path="M0 0 L100 0" dur="4s" repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(
        attributeAt(document, const Duration(seconds: 2), 'a', 'transform'),
        endsWith('scale(2)'),
      );
    });
  });

  group('document duration', () {
    test('is the longest active end when nothing repeats forever', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a">
            <animate attributeName="x" from="0" to="1" dur="1s"/>
            <animate attributeName="y" from="0" to="1" begin="2s" dur="3s"/>
          </rect>
        '''),
      );
      expect(document.duration, const Duration(seconds: 5));
      expect(document.loops, isFalse);
    });

    test('is a common multiple of the repeating iteration lengths', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a">
            <animate attributeName="x" from="0" to="1" dur="2s" repeatCount="indefinite"/>
            <animate attributeName="y" from="0" to="1" dur="3s" repeatCount="indefinite"/>
          </rect>
        '''),
      );
      expect(document.duration, const Duration(seconds: 6));
      expect(document.loops, isTrue);
    });

    test('extends the loop past a one-shot animation', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <rect id="a">
            <animate attributeName="x" from="0" to="1" dur="2s" repeatCount="indefinite"/>
            <animate attributeName="y" from="0" to="1" dur="5s"/>
          </rect>
        '''),
      );
      expect(document.duration, const Duration(seconds: 6));
    });
  });
}
