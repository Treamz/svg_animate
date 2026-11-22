import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/src/animation/document.dart';
import 'package:xml/xml.dart';

String svgWith(String body) =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">$body</svg>';

Duration ms(int value) => Duration(milliseconds: value);

double? numberAt(AnimatedSvgDocument document, Duration time, String id, String attribute) {
  final frame = XmlDocument.parse(document.sampleAt(time));
  for (final XmlElement element in frame.descendantElements) {
    if (element.getAttribute('id') == id) {
      final String? value = element.getAttribute(attribute);
      return value == null ? null : double.parse(value);
    }
  }
  fail('No element with id "$id" in the sampled frame.');
}

/// The shape of svg-spinners' "3-dots-bounce": the first dot restarts a
/// quarter second after the last one ends, and the others follow the first.
const String threeDots = '''
<circle id="d1" cx="4" cy="12" r="3">
  <animate id="a1" attributeName="cy" begin="0;a3.end+0.25s" dur="0.6s" values="12;6;12"/>
</circle>
<circle id="d2" cx="12" cy="12" r="3">
  <animate attributeName="cy" begin="a1.begin+0.1s" dur="0.6s" values="12;6;12"/>
</circle>
<circle id="d3" cx="20" cy="12" r="3">
  <animate id="a3" attributeName="cy" begin="a1.begin+0.2s" dur="0.6s" values="12;6;12"/>
</circle>''';

void main() {
  group('begin on another animation', () {
    test('a chain that restarts itself loops on the period it makes', () {
      final document = AnimatedSvgDocument.parse(svgWith(threeDots));
      // 0.2 s until the last dot starts, 0.6 s it runs, 0.25 s pause.
      expect(document.loops, isTrue);
      expect(document.duration, ms(1050));
    });

    test('each animation starts when the one it names says', () {
      final document = AnimatedSvgDocument.parse(svgWith(threeDots));
      // At 0.05 s only the first dot has started.
      expect(numberAt(document, ms(50), 'd1', 'cy'), lessThan(12));
      expect(numberAt(document, ms(50), 'd2', 'cy'), 12);
      expect(numberAt(document, ms(50), 'd3', 'cy'), 12);
      // At the top of the second dot's bounce: 0.1 s start + 0.3 s.
      expect(numberAt(document, ms(400), 'd2', 'cy'), closeTo(6, 0.01));
    });

    test('an animation that begins only on another one is no longer dropped', () {
      final document = AnimatedSvgDocument.parse(svgWith(threeDots));
      final List<double?> values = <double?>[
        for (int t = 0; t < 1050; t += 50) numberAt(document, ms(t), 'd3', 'cy'),
      ];
      expect(values.toSet().length, greaterThan(2));
    });

    test('a negative offset on an end is resolved before that end arrives', () {
      // svg-spinners' "bars-scale": restart a tenth of a second before the
      // last bar ends, which is only possible because a run's end is known as
      // soon as it begins.
      final document = AnimatedSvgDocument.parse(
        svgWith('''
<rect id="b1" width="2" height="12">
  <animate id="first" attributeName="height" begin="0;last.end-0.1s" dur="0.6s" values="12;22;12"/>
</rect>
<rect id="b2" width="2" height="12">
  <animate id="last" attributeName="height" begin="first.begin+0.4s" dur="0.6s" values="12;22;12"/>
</rect>'''),
      );
      expect(document.loops, isTrue);
      expect(document.duration, ms(900));
    });

    test('a chain that ends plays once and stops', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
<rect id="r" width="10" height="10">
  <animate id="grow" attributeName="width" begin="0s" dur="1s" values="10;50" fill="freeze"/>
  <animate attributeName="height" begin="grow.end" dur="0.5s" values="10;50" fill="freeze"/>
</rect>'''),
      );
      expect(document.loops, isFalse);
      expect(document.duration, ms(1500));
      expect(numberAt(document, ms(900), 'r', 'height'), 10);
      expect(numberAt(document, ms(1500), 'r', 'height'), 50);
    });

    test('a name that matches no animation leaves it out, as before', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
<rect id="r" width="10" height="10">
  <animate attributeName="width" begin="missing.end" dur="1s" values="10;50"/>
</rect>'''),
      );
      expect(document.isAnimated, isFalse);
    });
  });

  group('more than one begin time', () {
    test('each time in the list starts a run', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
<rect id="r" width="10" height="10">
  <animate attributeName="width" begin="0s;2s" dur="1s" values="10;50"/>
</rect>'''),
      );
      expect(numberAt(document, ms(500), 'r', 'width'), closeTo(30, 0.01));
      expect(numberAt(document, ms(1500), 'r', 'width'), 10);
      expect(numberAt(document, ms(2500), 'r', 'width'), closeTo(30, 0.01));
    });

    test('an event in the list is passed over and the time kept', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
<rect id="r" width="10" height="10">
  <animate attributeName="width" begin="click;1s" dur="1s" values="10;50"/>
</rect>'''),
      );
      expect(numberAt(document, ms(500), 'r', 'width'), 10);
      expect(numberAt(document, ms(1500), 'r', 'width'), closeTo(30, 0.01));
    });

    test('restart="never" ignores every begin after the first', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
<rect id="r" width="10" height="10">
  <animate attributeName="width" begin="0s;2s" dur="1s" values="10;50" restart="never"/>
</rect>'''),
      );
      expect(numberAt(document, ms(2500), 'r', 'width'), 10);
    });
  });

  group('which animation wins', () {
    test('the one whose run began last, once runs restart', () {
      // svg-spinners' "blocks-shuffle": four frozen animations take turns on
      // one attribute. The one written first restarts after the others, and
      // must then win over their frozen values.
      final document = AnimatedSvgDocument.parse(
        svgWith('''
<rect id="r" x="1" width="10" height="10">
  <animate id="right" attributeName="x" begin="0;left.end" dur="0.2s" values="1;13" fill="freeze"/>
  <animate id="left" attributeName="x" begin="right.end+0.2s" dur="0.2s" values="13;1" fill="freeze"/>
</rect>'''),
      );
      expect(document.duration, ms(600));
      expect(numberAt(document, ms(300), 'r', 'x'), 13);
      expect(numberAt(document, ms(500), 'r', 'x'), closeTo(7, 0.01));
      // Second loop, mid-way through "right" again: it began after "left"
      // froze at 1, so its value shows.
      expect(numberAt(document, ms(700), 'r', 'x'), closeTo(7, 0.01));
    });
  });

  group('a chain that overlaps its own period', () {
    test('is looped from its settled pattern, not from its warm-up', () {
      // svg-spinners' "pulse-3": each wave lasts longer than the gap between
      // waves, so from the second period on, the previous wave is still going
      // when the next starts. In the first period it is not. The loop shows
      // the settled pattern.
      final document = AnimatedSvgDocument.parse(
        svgWith(
          '''
<circle id="w1" r="0"><animate id="a" attributeName="r" begin="0;c.begin+0.4s" dur="1.2s" values="0;11"/></circle>
<circle id="w2" r="0"><animate attributeName="r" begin="a.begin+0.4s" dur="1.2s" values="0;11"/></circle>
<circle id="w3" r="0"><animate id="c" attributeName="r" begin="a.begin+0.8s" dur="1.2s" values="0;11"/></circle>''',
        ),
      );
      expect(document.duration, ms(1200));
      // At 0.05 s into the loop, the second and third waves are part-way
      // through the runs they began in the period before.
      expect(numberAt(document, ms(50), 'w2', 'r'), closeTo(11 * 0.85 / 1.2, 0.01));
      expect(numberAt(document, ms(50), 'w3', 'r'), closeTo(11 * 0.45 / 1.2, 0.01));
    });
  });
}
