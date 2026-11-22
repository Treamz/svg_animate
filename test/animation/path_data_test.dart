import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/src/animation/document.dart';
import 'package:svg_animate/src/animation/path_data.dart';
import 'package:svg_animate/src/animation/values.dart';
import 'package:xml/xml.dart';

String read(String raw) => PathDataValue.parse(raw)!.toAttributeValue();

/// The `d` of the one path in [body] at [milliseconds].
///
/// The expected values in these tests are what Chrome reports for the same
/// markup through `getComputedStyle(path).d`, with its spaces removed.
String? dAt(String body, int milliseconds) {
  final String frame = AnimatedSvgDocument.parse(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">$body</svg>',
  ).sampleAt(Duration(milliseconds: milliseconds));
  return XmlDocument.parse(frame).findAllElements('path').single.getAttribute('d');
}

void main() {
  group('path data', () {
    test('is read into absolute commands', () {
      expect(read('m10 10 l5 5 h5 v-5 z'), 'M10 10 L15 15 H20 V10 Z');
    });

    test('repeats a command when its letter is left out, with lines after a move', () {
      expect(read('M0 0 10 10 20 0'), 'M0 0 L10 10 L20 0');
      expect(read('m1 1 2 2'), 'M1 1 L3 3');
    });

    test('reads numbers that run together', () {
      expect(read('M.5.5L1-2'), 'M0.5 0.5 L1 -2');
      expect(read('M0,0L1e1,2E0'), 'M0 0 L10 2');
    });

    test('reads arc flags written without a space after them', () {
      expect(read('M0 0a5 5 0 0110 10'), 'M0 0 A5 5 0 0 1 10 10');
    });

    test('accepts the CSS form', () {
      expect(read('path("M0 0 L1 1")'), 'M0 0 L1 1');
    });

    test('is not read when it is not path data', () {
      expect(PathDataValue.parse('none'), isNull);
      expect(PathDataValue.parse('M0'), isNull);
      expect(parseAnimatableValue('d', 'none'), const KeywordValue('none'));
    });
  });

  group('an animated d', () {
    test('blends paths with the same commands', () {
      expect(
        dAt(
          '<path d="M0 0L10 10"><animate attributeName="d" to="M0 0L20 20" dur="1s"/></path>',
          450,
        ),
        'M0 0 L14.5 14.5',
      );
    });

    test('blends a relative command with its absolute twin', () {
      expect(
        dAt(
          '<path d="M0 0L10 10"><animate attributeName="d" to="M0 0l20 20" dur="1s"/></path>',
          700,
        ),
        'M0 0 L17 17',
      );
    });

    test('switches arc flags halfway and blends the rest', () {
      const String arc =
          '<path d="M0 0A5 5 0 0 0 10 10">'
          '<animate attributeName="d" to="M0 0A15 5 0 1 1 20 20" dur="1s"/></path>';

      expect(dAt(arc, 450), 'M0 0 A9.5 5 0 0 0 14.5 14.5');
      expect(dAt(arc, 550), 'M0 0 A10.5 5 0 1 1 15.5 15.5');
    });

    test('switches halfway between paths whose commands differ', () {
      const String path =
          '<path d="M0 0L10 10"><animate attributeName="d" to="M0 0H20" dur="1s"/></path>';

      expect(dAt(path, 450), 'M0 0 L10 10');
      expect(dAt(path, 550), 'M0 0 H20');
    });

    test('switches halfway through each step of a values list that cannot blend', () {
      // The first step cannot blend and switches at a quarter; the second can.
      const String path =
          '<path d="M0 0L10 10"><animate attributeName="d" dur="1s" '
          'values="M0 0L10 10;M0 0C1 1 2 2 20 20;M0 0C1 1 2 2 30 30"/></path>';

      expect(dAt(path, 200), 'M0 0 L10 10');
      expect(dAt(path, 300), 'M0 0 C1 1 2 2 20 20');
      expect(dAt(path, 750), 'M0 0 C1 1 2 2 25 25');
    });

    test('holds the last path once frozen', () {
      expect(
        dAt(
          '<path d="M0 0L10 10"><animate attributeName="d" to="M0 0L20 20" dur="1s" '
          'fill="freeze"/></path>',
          2000,
        ),
        'M0 0 L20 20',
      );
    });
  });

  test('a keyword switches halfway, where Chrome switches it', () {
    final String frame = AnimatedSvgDocument.parse('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
  <rect width="1" height="1" visibility="hidden">
    <animate attributeName="visibility" to="visible" dur="1s"/>
  </rect>
</svg>''').sampleAt(const Duration(milliseconds: 550));

    expect(frame, contains('visibility="visible"'));
  });
}
