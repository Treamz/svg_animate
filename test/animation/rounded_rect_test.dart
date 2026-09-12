import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/src/animation/document.dart';

/// The rect the progress bar in `example/assets/progress.svg` is built from:
/// a corner radius of 4 on a bar that grows from nothing.
const String growingBar = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 24">
  <rect x="2" y="8" width="0" height="8" rx="4" fill="#42a5f5">
    <animate attributeName="width" from="0" to="116" dur="2s" fill="freeze"/>
  </rect>
</svg>''';

String at(String svg, int milliseconds) =>
    AnimatedSvgDocument.parse(svg).sampleAt(Duration(milliseconds: milliseconds));

/// Samples one document at several times, which matters because the radius has
/// to be worked out afresh each time rather than folded into the source.
List<String> over(String svg, List<int> milliseconds) {
  final AnimatedSvgDocument document = AnimatedSvgDocument.parse(svg);
  return <String>[
    for (final int time in milliseconds) document.sampleAt(Duration(milliseconds: time)),
  ];
}

void main() {
  group('a corner radius larger than the side it rounds', () {
    test('is gone entirely while the rect has no width', () {
      final String frame = at(growingBar, 0);

      expect(frame, contains('width="0"'));
      expect(frame, isNot(contains('rx=')), reason: 'a corner with no width is not rounded');
      expect(frame, isNot(contains('ry=')));
    });

    test('is held to half the width while the rect is narrow', () {
      // Half of 8 is 4, so a bar 8 wide is the last one still clamped.
      final String frame = at('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 24">
  <rect x="2" y="8" width="3" height="8" rx="4" fill="#42a5f5">
    <animate attributeName="width" from="3" to="3" dur="2s" fill="freeze"/>
  </rect>
</svg>''', 0);

      expect(frame, contains('rx="1.5"'), reason: 'half of the width');
      expect(frame, contains('ry="4"'), reason: 'half of the height, so unchanged');
    });

    test('comes back once the rect is wide enough for it', () {
      // The trap: clamping into the source would square the corners for good.
      final List<String> frames = over(growingBar, <int>[0, 2000]);

      expect(frames.first, isNot(contains('rx=')));
      expect(frames.last, contains('width="116"'));
      expect(frames.last, contains('rx="4"'), reason: 'the authored radius, not the clamped one');
    });

    test('is clamped once for a rect that does not change size', () {
      final String frame = at('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 24">
  <rect x="0" y="0" width="4" height="20" rx="6" fill="#000"/>
  <circle cx="5" cy="5" r="2" fill="#f00">
    <animate attributeName="r" from="2" to="4" dur="1s" fill="freeze"/>
  </circle>
</svg>''', 0);

      expect(frame, contains('rx="2"'), reason: 'half of a width that never moves');
      expect(frame, contains('ry="6"'));
    });

    test('takes ry from rx when only one of them is written', () {
      final String frame = at('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 24">
  <rect x="0" y="0" width="20" height="3" ry="5" fill="#000"/>
</svg>''', 0);

      // ry stands for both, so the height clamps it to 1.5 and the width leaves
      // the horizontal radius alone.
      expect(frame, contains('rx="5"'));
      expect(frame, contains('ry="1.5"'));
    });

    test('is left alone when the size is not a plain number', () {
      // Guessing at what a percentage resolves to would be wrong more often
      // than doing nothing.
      final String frame = at('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 24">
  <rect x="0" y="0" width="2%" height="8" rx="4" fill="#000"/>
</svg>''', 0);

      expect(frame, contains('rx="4"'));
    });

    test('leaves a rect with no radius as it found it', () {
      final String frame = at('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 24">
  <rect x="0" y="0" width="0" height="8" fill="#000"/>
</svg>''', 0);

      expect(frame, isNot(contains('rx=')));
      expect(frame, isNot(contains('ry=')));
    });
  });
}
