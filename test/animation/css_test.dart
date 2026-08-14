import 'package:svg_animate/src/animation/css.dart';
import 'package:svg_animate/src/animation/document.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'document_test.dart' show attributeAt, svgWith;

XmlElement elementWithId(XmlDocument document, String id) => document.descendantElements.firstWhere(
  (XmlElement element) => element.getAttribute('id') == id,
);

void main() {
  group('CssStylesheet', () {
    test('parses rules, declarations, and important flags', () {
      final CssStylesheet stylesheet = CssStylesheet.parse('''
        /* a comment */
        .a, #b { fill: red; opacity: .5 !important }
        rect { stroke : blue ; }
      ''');
      expect(stylesheet.rules.length, 2);
      expect(stylesheet.rules.first.declarations['fill']!.value, 'red');
      expect(stylesheet.rules.first.declarations['opacity']!.important, isTrue);
      expect(stylesheet.rules.last.declarations['stroke']!.value, 'blue');
    });

    test('parses @keyframes, including from and to', () {
      final CssStylesheet stylesheet = CssStylesheet.parse('''
        @keyframes spin {
          from { transform: rotate(0deg); }
          50%, 75% { opacity: 0.5; }
          to { transform: rotate(360deg); }
        }
      ''');
      final CssKeyframes keyframes = stylesheet.keyframes['spin']!;
      expect(keyframes.keyframes.length, 3);
      expect(keyframes.keyframes.first.offsets, <double>[0]);
      expect(keyframes.keyframes[1].offsets, <double>[0.5, 0.75]);
      expect(keyframes.keyframes.last.offsets, <double>[1]);
    });

    test('skips at-rules it does not implement without losing the rest', () {
      final CssStylesheet stylesheet = CssStylesheet.parse('''
        @import url(other.css);
        @media (min-width: 100px) { rect { fill: red } }
        circle { fill: blue }
      ''');
      expect(stylesheet.rules.length, 1);
      expect(stylesheet.rules.single.declarations['fill']!.value, 'blue');
    });

    group('selectors', () {
      final document = XmlDocument.parse(
        svgWith('<g id="g" class="outer"><rect id="r" class="a b"/></g>'),
      );
      final XmlElement rect = elementWithId(document, 'r');

      test('match by type, class, id, and the universal selector', () {
        expect(CssSelector.parse('rect')!.matches(rect), isTrue);
        expect(CssSelector.parse('.a')!.matches(rect), isTrue);
        expect(CssSelector.parse('.a.b')!.matches(rect), isTrue);
        expect(CssSelector.parse('#r')!.matches(rect), isTrue);
        expect(CssSelector.parse('*')!.matches(rect), isTrue);
        expect(CssSelector.parse('circle')!.matches(rect), isFalse);
        expect(CssSelector.parse('.a.c')!.matches(rect), isFalse);
      });

      test('match descendant and child combinators', () {
        expect(CssSelector.parse('g rect')!.matches(rect), isTrue);
        expect(CssSelector.parse('g > rect')!.matches(rect), isTrue);
        expect(CssSelector.parse('.outer rect')!.matches(rect), isTrue);
        expect(CssSelector.parse('circle rect')!.matches(rect), isFalse);
        expect(CssSelector.parse('svg > rect')!.matches(rect), isFalse);
      });

      test('are rejected when they use unsupported syntax', () {
        expect(CssSelector.parse('rect:hover'), isNull);
        expect(CssSelector.parse('rect[fill]'), isNull);
      });

      test('order by specificity', () {
        expect(
          CssSelector.parse('#r')!.specificity,
          greaterThan(CssSelector.parse('.a')!.specificity),
        );
        expect(
          CssSelector.parse('.a')!.specificity,
          greaterThan(CssSelector.parse('rect')!.specificity),
        );
      });
    });
  });

  group('static CSS flattening', () {
    test('resolves the cascade into presentation attributes', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>rect { fill: red } .hero { fill: blue }</style>
          <rect id="a" class="hero" width="10" height="10"/>
        '''),
      );
      expect(attributeAt(document, Duration.zero, 'a', 'fill'), 'blue');
      expect(document.sampleAt(Duration.zero), isNot(contains('<style')));
    });

    test('lets inline styles win over stylesheet rules', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>#a { fill: red }</style>
          <rect id="a" style="fill: lime" width="10" height="10"/>
        '''),
      );
      expect(attributeAt(document, Duration.zero, 'a', 'fill'), 'lime');
      expect(attributeAt(document, Duration.zero, 'a', 'style'), isNull);
    });

    test('leaves out custom properties, which are not legal attribute names', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>.a { --brand: #ff0000; fill: #00ff00 }</style>
          <rect id="a" class="a" width="10" height="10"/>
        '''),
      );
      final String frame = document.sampleAt(Duration.zero);
      expect(frame, isNot(contains('--brand')));
      expect(attributeAt(document, Duration.zero, 'a', 'fill'), '#00ff00');
      // The frame has to survive a round trip through the compiler's parser.
      expect(() => XmlDocument.parse(frame), returnsNormally);
    });

    test('leaves an attribute alone when the CSS value references a variable', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>.a { fill: var(--brand, #00ff00) }</style>
          <rect id="a" class="a" fill="#ff0000" width="10" height="10"/>
        '''),
      );
      expect(attributeAt(document, Duration.zero, 'a', 'fill'), '#ff0000');
    });

    test('lets an important rule win over an inline style', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>rect { fill: red !important }</style>
          <rect id="a" style="fill: lime" width="10" height="10"/>
        '''),
      );
      expect(attributeAt(document, Duration.zero, 'a', 'fill'), 'red');
    });
  });

  group('CSS animation', () {
    test('runs a @keyframes rule named by the animation shorthand', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a { animation: fade 2s linear infinite; }
            @keyframes fade { from { opacity: 0 } to { opacity: 1 } }
          </style>
          <rect id="a" width="10" height="10"/>
        '''),
      );
      expect(document.duration, const Duration(seconds: 2));
      expect(document.loops, isTrue);
      expect(attributeAt(document, Duration.zero, 'a', 'opacity'), '0');
      expect(attributeAt(document, const Duration(seconds: 1), 'a', 'opacity'), '0.5');
    });

    test('reads longhand animation properties', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a {
              animation-name: fade;
              animation-duration: 2s;
              animation-timing-function: linear;
              animation-iteration-count: infinite;
            }
            @keyframes fade { from { opacity: 0 } to { opacity: 1 } }
          </style>
          <rect id="a" width="10" height="10"/>
        '''),
      );
      expect(attributeAt(document, const Duration(seconds: 1), 'a', 'opacity'), '0.5');
    });

    test('converts CSS transform syntax to SVG transform syntax', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a { animation: spin 4s linear infinite; }
            @keyframes spin {
              from { transform: rotate(0deg) }
              to { transform: rotate(360deg) }
            }
          </style>
          <rect id="a" width="10" height="10"/>
        '''),
      );
      expect(attributeAt(document, const Duration(seconds: 1), 'a', 'transform'), 'rotate(90)');
    });

    test('rotates about the transform origin, resolved against the view box', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a { transform-origin: center; animation: spin 4s linear infinite; }
            @keyframes spin {
              from { transform: rotate(0deg) }
              to { transform: rotate(360deg) }
            }
          </style>
          <rect id="a" width="10" height="10"/>
        '''),
      );
      expect(
        attributeAt(document, const Duration(seconds: 1), 'a', 'transform'),
        'translate(50 50) rotate(90) translate(-50 -50)',
      );
    });

    test('applies the transform origin to elements that are not animated', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>#a { transform-origin: 100% 0 }</style>
          <rect id="a" transform="rotate(45)" width="10" height="10"/>
        '''),
      );
      expect(
        attributeAt(document, Duration.zero, 'a', 'transform'),
        'translate(100 0) rotate(45) translate(-100 0)',
      );
    });

    test('holds the last frame when the fill mode is forwards', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a { animation: fade 1s linear forwards; }
            #b { animation: grow 4s linear infinite; }
            @keyframes fade { from { opacity: 0 } to { opacity: 1 } }
            @keyframes grow { from { width: 0 } to { width: 50 } }
          </style>
          <rect id="a" width="10" height="10"/>
          <rect id="b" height="10"/>
        '''),
      );
      expect(attributeAt(document, const Duration(seconds: 2), 'a', 'opacity'), '1');
    });

    test('honors the animation delay', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a { animation: fade 2s linear 1s infinite; }
            @keyframes fade { from { opacity: 0 } to { opacity: 1 } }
          </style>
          <rect id="a" opacity="0.25" width="10" height="10"/>
        '''),
      );
      expect(attributeAt(document, Duration.zero, 'a', 'opacity'), '0.25');
      expect(attributeAt(document, const Duration(seconds: 2), 'a', 'opacity'), '0.5');
    });

    test('alternates direction', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a { animation: fade 1s linear infinite alternate; }
            @keyframes fade { from { opacity: 0 } to { opacity: 1 } }
          </style>
          <rect id="a" width="10" height="10"/>
        '''),
      );
      expect(attributeAt(document, const Duration(milliseconds: 250), 'a', 'opacity'), '0.25');
      expect(attributeAt(document, const Duration(milliseconds: 1250), 'a', 'opacity'), '0.75');
    });

    test('fills in a missing 0% keyframe from the element itself', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a { animation: fade 2s linear infinite; }
            @keyframes fade { to { opacity: 1 } }
          </style>
          <rect id="a" opacity="0" width="10" height="10"/>
        '''),
      );
      expect(attributeAt(document, const Duration(seconds: 1), 'a', 'opacity'), '0.5');
    });

    test('never runs a paused animation', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>
            #a { animation: fade 2s linear infinite paused; }
            @keyframes fade { from { opacity: 0 } to { opacity: 1 } }
          </style>
          <rect id="a" width="10" height="10"/>
        '''),
      );
      expect(document.isAnimated, isFalse);
    });

    test('ignores an animation whose keyframes are missing', () {
      final document = AnimatedSvgDocument.parse(
        svgWith('''
          <style>#a { animation: nothere 2s linear infinite; }</style>
          <rect id="a" width="10" height="10"/>
        '''),
      );
      expect(document.isAnimated, isFalse);
      expect(attributeAt(document, Duration.zero, 'a', 'animation'), isNull);
    });
  });
}
