import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart' show PictureInfo, vg;
import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/src/animation/diagnostics.dart' show debugCompilerDrawsPrimitive;
import 'package:svg_animate/src/animation/frames.dart' show AnimatedSvgFrameLoader;
import 'package:svg_animate/svg_animate.dart';

Future<List<SvgAnimateDiagnostic>> diagnose(String svg, {int maxFrames = 300}) async {
  final AnimatedSvgFrames frames = await compileAnimatedSvg(svg, maxFrames: maxFrames);
  return frames.diagnostics;
}

/// A black square from 30 to 70 in a 100-unit picture, blurred.
const String blurredSquare = '''
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">
  <defs>
    <filter id="b" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="6"/>
    </filter>
  </defs>
  <rect x="30" y="30" width="40" height="40" fill="#000" filter="url(#b)">
    <animate attributeName="opacity" values="1;0.5;1" dur="1s" repeatCount="indefinite"/>
  </rect>
</svg>''';

/// How opaque the compiled frame draws the pixel three units left of a square
/// whose left edge is at 30: zero for a hard edge, more for a blurred one.
Future<int> alphaOutside(String svg, {bool lastFrame = false}) async {
  final AnimatedSvgFrames frames = await compileAnimatedSvg(svg, frameRate: 10);
  final PictureInfo info = await vg.loadPicture(
    AnimatedSvgFrameLoader(frames, lastFrame ? frames.frameCount - 1 : 0),
    null,
  );
  final ui.Image image = await info.picture.toImage(100, 100);
  final ByteData pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  info.picture.dispose();
  return pixels.getUint8((50 * 100 + 27) * 4 + 3);
}

Set<SvgAnimateDiagnosticKind> kinds(List<SvgAnimateDiagnostic> diagnostics) =>
    diagnostics.map((SvgAnimateDiagnostic d) => d.kind).toSet();

/// An animation big enough to be worth warning about, built rather than
/// written out.
///
/// The transform is on the group on purpose: the compiler bakes transforms into
/// the points, so every frame carries its own copy of every path and the size
/// is real rather than an artefact of how the frames are stored.
String heavy({int paths = 40, int points = 400}) {
  final buffer = StringBuffer(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000">'
    '<g><animateTransform attributeName="transform" type="translate" '
    'values="0 0;40 40" dur="1s" repeatCount="indefinite"/>',
  );
  for (var path = 0; path < paths; path++) {
    buffer.write('<path fill="none" stroke="#123456" d="M0 $path');
    for (var point = 1; point < points; point++) {
      buffer.write(' L$point ${(path + point) % 1000}');
    }
    buffer.write('"/>');
  }
  buffer.write('</g></svg>');
  return buffer.toString();
}

const String movingRect = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="10" height="10" fill="#f00">
    <animate attributeName="x" dur="1s" values="0;90" repeatCount="indefinite"/>
  </rect>
</svg>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('diagnostics', () {
    test('an animation that works reports nothing', () async {
      expect(await diagnose(movingRect), isEmpty);
    });

    test('names the script when a document has one and no animation', () async {
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="10" height="10" fill="#f00"/>
  <script>window.__PLAYER__ = {};</script>
</svg>''');

      expect(kinds(found), <SvgAnimateDiagnosticKind>{SvgAnimateDiagnosticKind.noAnimation});
      expect(found.single.message, contains('<script>'));
    });

    test('does not blame a script that is not there', () async {
      final List<SvgAnimateDiagnostic> found = await diagnose(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="5" height="5"/></svg>',
      );

      expect(kinds(found), <SvgAnimateDiagnosticKind>{SvgAnimateDiagnosticKind.noAnimation});
      expect(found.single.message, isNot(contains('script')));
    });

    test('reports an image the compiler will not fetch, and names it', () async {
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 100">
  <rect width="10" height="10" fill="#f00">
    <animate attributeName="x" dur="1s" values="0;90" repeatCount="indefinite"/>
  </rect>
  <image width="100" height="100" xlink:href="https://example.com/photo.jpeg"/>
</svg>''');

      expect(kinds(found), <SvgAnimateDiagnosticKind>{SvgAnimateDiagnosticKind.unreachableImage});
      expect(found.single.message, contains('https://example.com/photo.jpeg'));
    });

    test('says nothing about an image that is embedded', () async {
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="10" height="10" fill="#f00">
    <animate attributeName="x" dur="1s" values="0;90" repeatCount="indefinite"/>
  </rect>
  <image width="1" height="1" href="data:image/png;base64,iVBORw0KGgo="/>
</svg>''');

      expect(found, isEmpty);
    });

    test('reports a filter the renderer cannot draw, and names what in it', () async {
      // The drop shadow design tools export: a flood colour composited into
      // the blurred alpha. No version of vector_graphics draws feFlood yet, so
      // this is reported whichever one is resolved.
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="s">
      <feGaussianBlur in="SourceAlpha" stdDeviation="3"/>
      <feFlood flood-color="#000" flood-opacity="0.5"/>
      <feComposite operator="in" in2="SourceAlpha"/>
    </filter>
  </defs>
  <rect width="50" height="50" fill="#f00" filter="url(#s)">
    <animate attributeName="x" dur="1s" values="0;40" repeatCount="indefinite"/>
  </rect>
</svg>''');

      expect(kinds(found), <SvgAnimateDiagnosticKind>{SvgAnimateDiagnosticKind.droppedFilter});
      expect(found.single.message, contains('1 filter'));
      expect(found.single.message, contains('feFlood, feComposite'));
    });

    test('says nothing about a blur the renderer draws', () async {
      // Asked of the pixels rather than of the compiler, so that the diagnostic
      // is checked against what is drawn and not against the way it decides.
      expect(
        await alphaOutside(blurredSquare.replaceFirst(' filter="url(#b)"', '')),
        0,
        reason: 'the unfiltered square must have a hard edge, or nothing below means anything',
      );
      // vector_graphics_compiler 1.3.6, which Flutter 3.41 and later resolve,
      // draws the blur; an earlier one does not, and must still be reported.
      final bool drawn = await alphaOutside(blurredSquare) > 0;
      final List<SvgAnimateDiagnostic> found = await diagnose(blurredSquare);
      if (drawn) {
        expect(found, isEmpty, reason: 'the blur is on the screen, so reporting it would be false');
      } else {
        expect(kinds(found), <SvgAnimateDiagnosticKind>{SvgAnimateDiagnosticKind.droppedFilter});
      }
    });

    test('nor about one whose stdDeviation is animated up from zero', () async {
      // At zero the blur compiles to the same bytes as no blur, which is why
      // the compiler is asked about the kind of primitive and not about the
      // filter as the document writes it.
      const String svg = '''
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">
  <defs>
    <filter id="b" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="0">
        <animate attributeName="stdDeviation" values="0;6" dur="1s" fill="freeze"/>
      </feGaussianBlur>
    </filter>
  </defs>
  <rect x="30" y="30" width="40" height="40" fill="#000" filter="url(#b)"/>
</svg>''';

      expect(await alphaOutside(svg), 0, reason: 'a blur of zero at the start');
      final bool drawn = await alphaOutside(svg, lastFrame: true) > 0;
      expect(
        kinds(await diagnose(svg)).contains(SvgAnimateDiagnosticKind.droppedFilter),
        !drawn,
        reason: drawn ? 'the blur is on the screen by the end' : 'the blur is never drawn',
      );
    });

    test('counts only the filters that are left out', () async {
      debugCompilerDrawsPrimitive = (String primitive) => primitive != 'feFlood';
      addTearDown(() => debugCompilerDrawsPrimitive = null);

      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="a"><feGaussianBlur stdDeviation="2"/></filter>
    <filter id="b"><feFlood flood-color="#000"/><feComposite operator="in" in2="SourceGraphic"/></filter>
  </defs>
  <rect width="20" height="20" fill="#f00" filter="url(#a)">
    <animate attributeName="x" dur="1s" values="0;40" repeatCount="indefinite"/>
  </rect>
  <rect x="50" width="20" height="20" fill="#00f" filter="url(#b)"/>
</svg>''');

      expect(found.single.message, contains('1 filter that'));
      expect(found.single.message, contains('here it does not draw feFlood.'));
      expect(found.single.message, isNot(contains('Flutter 3.41')));
    });

    group('under a compiler that draws no filters', () {
      // What an app on a Flutter older than 3.41 resolves, and so what these
      // messages are read under there.
      setUp(() => debugCompilerDrawsPrimitive = (String primitive) => false);
      tearDown(() => debugCompilerDrawsPrimitive = null);

      test(
        'says a newer Flutter draws a blur, and offers the widget-layer one meanwhile',
        () async {
          final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs><filter id="b"><feGaussianBlur stdDeviation="3"/></filter></defs>
  <rect width="50" height="50" fill="#f00" filter="url(#b)">
    <animate attributeName="x" dur="1s" values="0;40" repeatCount="indefinite"/>
  </rect>
</svg>''');

          expect(kinds(found), <SvgAnimateDiagnosticKind>{SvgAnimateDiagnosticKind.droppedFilter});
          expect(found.single.message, contains('1 filter.'));
          expect(found.single.message, contains('need Flutter 3.41'));
          expect(found.single.message, contains('which is everything this filter uses'));
          expect(found.single.message, contains('ImageFilter.blur(sigmaX: 3.0, sigmaY: 3.0)'));
        },
      );

      test('carries both axes of a stdDeviation that gives two', () async {
        final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs><filter id="b"><feGaussianBlur stdDeviation="2 4.5"/></filter></defs>
  <rect width="50" height="50" fill="#f00" filter="url(#b)">
    <animate attributeName="x" dur="1s" values="0;40" repeatCount="indefinite"/>
  </rect>
</svg>''');

        expect(found.single.message, contains('ImageFilter.blur(sigmaX: 2.0, sigmaY: 4.5)'));
      });

      test('offers no widget-layer substitute for a filter that does more than blur', () async {
        // A blur plus an offset is a drop shadow, and blurring the whole
        // picture is not one. A newer Flutter draws it, which is the way out.
        final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="s">
      <feGaussianBlur stdDeviation="3"/>
      <feOffset dx="2" dy="2"/>
    </filter>
  </defs>
  <rect width="50" height="50" fill="#f00" filter="url(#s)">
    <animate attributeName="x" dur="1s" values="0;40" repeatCount="indefinite"/>
  </rect>
</svg>''');

        expect(found.single.message, contains('which is everything this filter uses'));
        expect(found.single.message, isNot(contains('ImageFiltered')));
      });

      test('offers none when two different filters are used', () async {
        // One blur over the whole picture cannot stand in for two of them.
        final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <filter id="a"><feGaussianBlur stdDeviation="2"/></filter>
    <filter id="b"><feGaussianBlur stdDeviation="6"/></filter>
  </defs>
  <rect width="20" height="20" fill="#f00" filter="url(#a)">
    <animate attributeName="x" dur="1s" values="0;40" repeatCount="indefinite"/>
  </rect>
  <rect x="50" width="20" height="20" fill="#00f" filter="url(#b)"/>
</svg>''');

        expect(found.single.message, contains('2 filters'));
        expect(found.single.message, contains('which is everything these filters use'));
        expect(found.single.message, isNot(contains('ImageFiltered')));
      });

      test('offers none for a blur of zero, which would change nothing', () async {
        final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs><filter id="b"><feGaussianBlur/></filter></defs>
  <rect width="50" height="50" fill="#f00" filter="url(#b)">
    <animate attributeName="x" dur="1s" values="0;40" repeatCount="indefinite"/>
  </rect>
</svg>''');

        expect(found.single.message, isNot(contains('ImageFiltered')));
      });

      test('says when a newer Flutter would still leave the filter out', () async {
        final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs><filter id="b"><feFlood flood-color="#000"/></filter></defs>
  <rect width="50" height="50" fill="#f00" filter="url(#b)">
    <animate attributeName="x" dur="1s" values="0;40" repeatCount="indefinite"/>
  </rect>
</svg>''');

        expect(
          found.single.message,
          contains('but not feFlood, so this filter would still be left out'),
        );
      });
    });

    test('does not mistake a gradient in a style for a filter', () async {
      // `fill: url(#…)` is far more common than a filter, and gradients draw.
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs>
    <linearGradient id="g"><stop offset="0%" stop-color="#f00"/></linearGradient>
  </defs>
  <rect width="50" height="50" style="fill: url(#g)">
    <animate attributeName="x" dur="1s" values="0;40" repeatCount="indefinite"/>
  </rect>
</svg>''');

      expect(found, isEmpty);
    });

    test('says what a large animation cost, and which knob changes it', () async {
      // Compiling is where this package spends, and the bill arrives as memory,
      // as a slow first frame, or on the web as a frozen tab — none of which
      // points back at the SVG that caused it.
      final List<SvgAnimateDiagnostic> found = await diagnose(heavy());

      expect(kinds(found), contains(SvgAnimateDiagnosticKind.expensive));
      final SvgAnimateDiagnostic cost = found.firstWhere(
        (SvgAnimateDiagnostic d) => d.kind == SvgAnimateDiagnosticKind.expensive,
      );
      expect(cost.message, contains(' MB'));
      expect(cost.message, contains('60 frames'));
      expect(cost.message, contains('frameRate'), reason: 'saying it is big is only half of it');
      expect(cost.message, contains('maxFrames'));
    });

    test('says nothing about one of an ordinary size', () async {
      expect(
        kinds(await diagnose(movingRect)),
        isNot(contains(SvgAnimateDiagnosticKind.expensive)),
      );
    });

    test('reports an animation whose every frame draws the same picture', () async {
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="10" height="10" fill="#f00">
    <animate attributeName="x" dur="1s" repeatCount="indefinite" values="20;20"/>
  </rect>
</svg>''');

      expect(kinds(found), contains(SvgAnimateDiagnosticKind.neverChanges));
      expect(found.last.message, contains('"x"'));
    });

    test('does not claim the values changed when they never did', () async {
      // `values="42"` has one value, so nothing was ever going to move. The
      // message used to open by asserting that the values changed and only the
      // drawing did not, which sends the reader after a renderer limitation
      // that is not there.
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="10" height="10" fill="#f00">
    <animate attributeName="x" dur="1s" values="42" repeatCount="indefinite"/>
  </rect>
</svg>''');

      final SvgAnimateDiagnostic still = found.firstWhere(
        (SvgAnimateDiagnostic d) => d.kind == SvgAnimateDiagnosticKind.neverChanges,
      );
      expect(still.message, isNot(contains('the values change')));
      expect(still.message, contains('single value'));
    });

    test('and offers the other cause for an animation that never runs', () async {
      // Told to begin after it ends, so no value is ever written. The same
      // sentence has to cover it, since the frames look identical either way.
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="10" height="10" fill="#f00">
    <animate attributeName="x" dur="1s" begin="5s" end="1s" values="0;90"/>
  </rect>
</svg>''');

      final SvgAnimateDiagnostic still = found.firstWhere(
        (SvgAnimateDiagnostic d) => d.kind == SvgAnimateDiagnosticKind.neverChanges,
      );
      expect(still.message, contains('begin after it ends'));
    });

    test('says nothing about a dash offset, which now draws', () async {
      // Drawing a path on is normally written this way. The compiler carries no
      // dash offset, so this used to compile to one frame repeated; the dashes
      // are now laid out before it sees them.
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 20">
  <path d="M5 10 L95 10" stroke="#f00" stroke-width="4" fill="none"
        stroke-dasharray="90" stroke-dashoffset="90">
    <animate attributeName="stroke-dashoffset" from="90" to="0" dur="1s"
             repeatCount="indefinite"/>
  </path>
</svg>''');

      expect(
        found.map((SvgAnimateDiagnostic d) => d.kind),
        isNot(contains(SvgAnimateDiagnosticKind.neverChanges)),
      );
    });

    test('says nothing about an animated d, which now morphs', () async {
      // Path data used to be held as one keyword and switched only at the very
      // end of each step, so a looping morph never left its first shape.
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <path d="M0 0 L10 0 L10 10 Z" fill="#f00">
    <animate attributeName="d" dur="1s" repeatCount="indefinite"
             values="M0 0 L10 0 L10 10 Z;M0 0 L90 0 L90 90 Z"/>
  </path>
</svg>''');

      expect(kinds(found), isNot(contains(SvgAnimateDiagnosticKind.neverChanges)));
    });

    test('reports a clip over text, which will not reach it', () async {
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 48">
  <defs><clipPath id="w"><rect x="0" y="0" width="60" height="48">
    <animate attributeName="width" values="0;120" dur="1s" repeatCount="indefinite"/>
  </rect></clipPath></defs>
  <g clip-path="url(#w)"><text x="10" y="30">hello</text></g>
</svg>''');

      expect(kinds(found), contains(SvgAnimateDiagnosticKind.unclippedText));
    });

    test('and finds it through a style as well as an attribute', () async {
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 48">
  <defs><clipPath id="w"><rect x="0" y="0" width="60" height="48">
    <animate attributeName="width" values="0;120" dur="1s" repeatCount="indefinite"/>
  </rect></clipPath></defs>
  <text x="10" y="30" style="clip-path: url(#w)">hello</text>
</svg>''');

      expect(kinds(found), contains(SvgAnimateDiagnosticKind.unclippedText));
    });

    test('says nothing when the clip is over shapes, which it does reach', () async {
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 48">
  <defs><clipPath id="w"><rect x="0" y="0" width="60" height="48">
    <animate attributeName="width" values="0;120" dur="1s" repeatCount="indefinite"/>
  </rect></clipPath></defs>
  <g clip-path="url(#w)"><rect width="120" height="48" fill="#f00"/></g>
</svg>''');

      expect(found, isEmpty);
    });

    test('reports being sampled below the requested rate, and says the rate', () async {
      // Two seconds at 60 fps wants 120 frames; 30 are allowed.
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="10" height="10" fill="#f00">
    <animate attributeName="x" dur="2s" values="0;90" repeatCount="indefinite"/>
  </rect>
</svg>''', maxFrames: 30);

      expect(kinds(found), <SvgAnimateDiagnosticKind>{SvgAnimateDiagnosticKind.reducedFrameRate});
      expect(found.single.message, contains('15.0 fps'));
    });

    test('says nothing about the rate when every frame asked for was compiled', () async {
      expect(
        kinds(await diagnose(movingRect)),
        isNot(contains(SvgAnimateDiagnosticKind.reducedFrameRate)),
      );
    });
  });
}
