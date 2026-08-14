import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/src/animation/document.dart';
import 'package:xml/xml.dart';

import 'document_test.dart' show svgWith;

const String _pixel =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

XmlDocument frameOf(String body) =>
    XmlDocument.parse(AnimatedSvgDocument.parse(svgWith(body)).sampleAt(Duration.zero));

Iterable<XmlElement> elementsNamed(XmlDocument document, String name) =>
    document.descendantElements.where((XmlElement element) => element.name.local == name);

void main() {
  group('expanding <use> of an <image>', () {
    test('replaces the reference with the image, keeping its size', () {
      final XmlDocument frame = frameOf('''
        <defs><image id="i" width="40" height="20" xlink:href="$_pixel"
            xmlns:xlink="http://www.w3.org/1999/xlink"/></defs>
        <use href="#i"/>
      ''');

      expect(elementsNamed(frame, 'use'), isEmpty);
      // The one in `defs` plus the copy that replaced the reference.
      final List<XmlElement> images = elementsNamed(frame, 'image').toList();
      expect(images.length, 2);
      final XmlElement inlined = images.last;
      expect(inlined.getAttribute('width'), '40');
      expect(inlined.getAttribute('height'), '20');
      expect(inlined.getAttribute('id'), isNull, reason: 'the copy must not duplicate the id');
    });

    test('leaves a reference to a shape alone', () {
      final XmlDocument frame = frameOf('''
        <defs><rect id="r" width="10" height="10"/></defs>
        <use href="#r"/>
      ''');
      expect(elementsNamed(frame, 'use'), hasLength(1));
    });

    test('turns x and y on the reference into a translate', () {
      final XmlDocument frame = frameOf('''
        <defs><image id="i" width="10" height="10" xlink:href="$_pixel"
            xmlns:xlink="http://www.w3.org/1999/xlink"/></defs>
        <use href="#i" x="5" y="7"/>
      ''');
      expect(elementsNamed(frame, 'image').last.getAttribute('transform'), 'translate(5 7)');
    });

    test('composes the reference transform outside the image one', () {
      final XmlDocument frame = frameOf('''
        <defs><image id="i" width="10" height="10" transform="scale(2)" xlink:href="$_pixel"
            xmlns:xlink="http://www.w3.org/1999/xlink"/></defs>
        <use href="#i" transform="rotate(45)" x="1" y="2"/>
      ''');
      expect(
        elementsNamed(frame, 'image').last.getAttribute('transform'),
        'rotate(45) translate(1 2) scale(2)',
      );
    });

    test('carries the reference presentation attributes over', () {
      final XmlDocument frame = frameOf('''
        <defs><image id="i" width="10" height="10" xlink:href="$_pixel"
            xmlns:xlink="http://www.w3.org/1999/xlink"/></defs>
        <use href="#i" opacity="0.5"/>
      ''');
      expect(elementsNamed(frame, 'image').last.getAttribute('opacity'), '0.5');
    });

    test('ignores a reference that resolves to nothing', () {
      final XmlDocument frame = frameOf('<use href="#missing"/>');
      expect(elementsNamed(frame, 'use'), hasLength(1));
    });
  });
}
