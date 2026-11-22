import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/src/animation/document.dart';
import 'package:xml/xml.dart';

String at(String svg, int milliseconds) =>
    AnimatedSvgDocument.parse(svg).sampleAt(Duration(milliseconds: milliseconds));

/// The elements of [frame] with the tag [name], in document order.
List<XmlElement> elements(String frame, String name) =>
    XmlDocument.parse(frame).findAllElements(name).toList();

/// A 100 unit line drawn on over a second, the way icon sets write it.
const String drawnOn = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 20">
  <path d="M0 10 H100" stroke="#000" fill="none" stroke-dasharray="100" stroke-dashoffset="100">
    <animate attributeName="stroke-dashoffset" to="0" dur="1s" fill="freeze"/>
  </path>
</svg>''';

void main() {
  group('a dash offset', () {
    test('draws nothing while the whole line sits in the gap', () {
      final XmlElement path = elements(at(drawnOn, 0), 'path').single;

      expect(path.getAttribute('stroke'), 'none');
    });

    test('moves the dash along the path as it is animated', () {
      // An offset of 75 into a dash of 100 leaves 25 of the dash at the start.
      final XmlElement path = elements(at(drawnOn, 250), 'path').single;

      expect(path.getAttribute('d'), 'M0 10L25 10');
      expect(
        path.getAttribute('stroke-dasharray'),
        'none',
        reason: 'the dash is in the geometry now',
      );
      expect(path.getAttribute('stroke-dashoffset'), isNull);
    });

    test('draws the whole line once the offset reaches zero', () {
      final XmlElement path = elements(at(drawnOn, 1000), 'path').single;

      expect(path.getAttribute('d'), 'M0 10 H100', reason: 'the shape as authored, undashed');
      expect(path.getAttribute('stroke-dasharray'), 'none');
      expect(path.getAttribute('stroke'), '#000');
    });

    test('that starts in a gap still begins with the gap', () {
      // A pattern of 4 on, 4 off, moved back by 2, starts 2 units into a gap,
      // which the compiler's dasher cannot be asked for directly.
      final XmlElement path = elements(
        at('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 4">
  <path d="M0 2 H20" stroke="#000" fill="none" stroke-dasharray="4 4" stroke-dashoffset="-2"/>
</svg>''', 0),
        'path',
      ).single;

      expect(path.getAttribute('d'), 'M2 2L6 2M10 2L14 2M18 2L20 2');
    });

    test('inherited from a group reaches each path, and the animated one moves', () {
      final List<XmlElement> paths = elements(
        at('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20">
  <g fill="none" stroke="#000" stroke-dasharray="10" stroke-dashoffset="10">
    <path d="M0 5 H10"><animate attributeName="stroke-dashoffset" to="0" dur="1s" fill="freeze"/></path>
    <path d="M0 15 H10"/>
  </g>
</svg>''', 500),
        'path',
      );

      expect(paths[0].getAttribute('d'), 'M0 5L5 5');
      expect(paths[1].getAttribute('stroke'), 'none', reason: 'still hidden by the group offset');
    });
  });

  group('a dash pattern laid out here', () {
    test('starts again at every subpath, as browsers draw it', () {
      // The compiler carries the pattern on from one subpath to the next, so
      // the second stroke would start 4 units into a gap and draw nothing.
      final XmlElement path = elements(
        at('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
  <path d="M0 2 H10 M0 8 H10" stroke="#000" fill="none" stroke-dasharray="6" stroke-dashoffset="0"/>
</svg>''', 0),
        'path',
      ).single;

      expect(path.getAttribute('d'), 'M0 2L6 2M0 8L6 8');
    });

    test('measures the dash in pathLength units when the path gives one', () {
      final XmlElement path = elements(
        at('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 4">
  <path d="M0 2 H40" pathLength="1" stroke="#000" fill="none"
        stroke-dasharray="1" stroke-dashoffset="0.5"/>
</svg>''', 0),
        'path',
      ).single;

      expect(path.getAttribute('d'), 'M0 2L20 2');
      expect(path.getAttribute('pathLength'), isNull);
    });

    test('starts a rect at its top left corner, going clockwise', () {
      final XmlElement stroke = elements(
        at('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
  <rect width="10" height="10" fill="none" stroke="#000" stroke-dasharray="15 100" stroke-dashoffset="0"/>
</svg>''', 0),
        'path',
      ).single;

      expect(stroke.getAttribute('d'), 'M0 0L10 0L10 5');
    });

    test('leaves the fill to the shape and moves the stroke to a copy after it', () {
      final String frame = at('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20">
  <circle id="dot" cx="10" cy="10" r="5" fill="#f00" stroke="#000" stroke-width="2"
          stroke-dasharray="4" stroke-dashoffset="1"/>
</svg>''', 0);
      final XmlElement circle = elements(frame, 'circle').single;
      final XmlElement stroke = elements(frame, 'path').single;

      expect(circle.getAttribute('fill'), '#f00');
      expect(circle.getAttribute('stroke'), 'none');
      expect(stroke.getAttribute('fill'), 'none');
      expect(stroke.getAttribute('stroke'), '#000');
      expect(stroke.getAttribute('stroke-width'), '2');
      expect(stroke.getAttribute('id'), isNull, reason: 'an id names one element');
      expect(
        circle.nextElementSibling?.toXmlString(),
        stroke.toXmlString(),
        reason: 'drawn straight after the fill',
      );
    });

    test('is laid out afresh for every frame', () {
      // The document is shared between frames, so whatever one frame writes
      // must be gone before the next is sampled.
      final AnimatedSvgDocument document = AnimatedSvgDocument.parse(drawnOn);
      final String late = document.sampleAt(const Duration(milliseconds: 750));
      final String early = document.sampleAt(const Duration(milliseconds: 250));

      expect(early, at(drawnOn, 250));
      expect(late, at(drawnOn, 750));
      expect(document.sampleAt(const Duration(milliseconds: 250)), early);
    });
  });

  test('a dash array with no offset or pathLength is left to the compiler', () {
    // Nothing to fix, and it compiles exactly as it did before.
    final XmlElement path = elements(
      at('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 4">
  <path d="M0 2 H20" stroke="#000" fill="none" stroke-dasharray="4">
    <animate attributeName="stroke-width" from="1" to="2" dur="1s"/>
  </path>
</svg>''', 0),
      'path',
    ).single;

    expect(path.getAttribute('d'), 'M0 2 H20');
    expect(path.getAttribute('stroke-dasharray'), '4');
  });
}
