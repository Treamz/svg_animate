import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/svg_animate.dart';

Future<List<SvgAnimateDiagnostic>> diagnose(String svg, {int maxFrames = 300}) async {
  final AnimatedSvgFrames frames = await compileAnimatedSvg(svg, maxFrames: maxFrames);
  return frames.diagnostics;
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

    test('reports a filter that is used', () async {
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs><filter id="b"><feGaussianBlur stdDeviation="4"/></filter></defs>
  <rect width="50" height="50" fill="#f00" filter="url(#b)">
    <animate attributeName="x" dur="1s" values="0;40" repeatCount="indefinite"/>
  </rect>
</svg>''');

      expect(kinds(found), <SvgAnimateDiagnosticKind>{SvgAnimateDiagnosticKind.droppedFilter});
      expect(found.single.message, contains('1 filter'));
    });

    test('offers the widget-layer blur when the filter is only a blur', () async {
      // The one substitution that exists: vector_graphics cannot blur an element
      // inside the picture, and Flutter can blur the picture, so the diagnostic
      // that used to end at "nothing can be done" now ends with how.
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs><filter id="b"><feGaussianBlur stdDeviation="3"/></filter></defs>
  <rect width="50" height="50" fill="#f00" filter="url(#b)">
    <animate attributeName="x" dur="1s" values="0;40" repeatCount="indefinite"/>
  </rect>
</svg>''');

      expect(found.single.message, contains('ImageFiltered'));
      expect(found.single.message, contains('ImageFilter.blur(sigmaX: 3.0, sigmaY: 3.0)'));
      expect(
        found.single.message,
        isNot(contains('Nothing in this package can add them')),
        reason: 'there is something, and the message now says what',
      );
    });

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

    test('offers nothing for a filter that does more than blur', () async {
      // A blur plus an offset is a drop shadow, and blurring the whole picture
      // is not one. Saying there is no way beats sending somebody after a
      // substitution that will not look like what they asked for.
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

      expect(found.single.message, contains('Nothing in this package can add them'));
      expect(found.single.message, isNot(contains('ImageFiltered')));
    });

    test('offers nothing when two different filters are used', () async {
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
      expect(found.single.message, isNot(contains('ImageFiltered')));
    });

    test('offers nothing for a blur of zero, which would change nothing', () async {
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs><filter id="b"><feGaussianBlur/></filter></defs>
  <rect width="50" height="50" fill="#f00" filter="url(#b)">
    <animate attributeName="x" dur="1s" values="0;40" repeatCount="indefinite"/>
  </rect>
</svg>''');

      expect(found.single.message, isNot(contains('ImageFiltered')));
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
  <path d="M0 0 L10 0 L10 10 Z" fill="#f00">
    <animate attributeName="d" dur="1s" repeatCount="indefinite"
             values="M0 0 L10 0 L10 10 Z;M0 0 L90 0 L90 90 Z"/>
  </path>
</svg>''');

      expect(kinds(found), contains(SvgAnimateDiagnosticKind.neverChanges));
      expect(found.last.message, contains('"d"'));
    });

    test('names an animated stroke-dashoffset, and the way round it', () async {
      // The one worth naming. Drawing a path on is normally written this way,
      // the values are written into every frame correctly, and the renderer
      // carries no dash offset — so nothing moves and nothing says why.
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 20">
  <path d="M5 10 L95 10" stroke="#f00" stroke-width="4" fill="none"
        stroke-dasharray="90" stroke-dashoffset="90">
    <animate attributeName="stroke-dashoffset" from="90" to="0" dur="1s"
             repeatCount="indefinite"/>
  </path>
</svg>''');

      final SvgAnimateDiagnostic still = found.firstWhere(
        (SvgAnimateDiagnostic d) => d.kind == SvgAnimateDiagnosticKind.neverChanges,
      );
      expect(still.message, contains('"stroke-dashoffset"'));
      expect(still.message, contains('"stroke-dasharray"'));
      expect(still.message, contains('0 L'), reason: 'the way round it, not just the name');
    });

    test('says an animated d never reaches the frames at all', () async {
      // A different failure from the dash offset, and worth telling apart: this
      // one never gets written, rather than being written and then dropped.
      final List<SvgAnimateDiagnostic> found = await diagnose('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <path d="M0 0 L10 0 L10 10 Z" fill="#f00">
    <animate attributeName="d" dur="1s" repeatCount="indefinite"
             values="M0 0 L10 0 L10 10 Z;M0 0 L90 0 L90 90 Z"/>
  </path>
</svg>''');

      final SvgAnimateDiagnostic still = found.firstWhere(
        (SvgAnimateDiagnostic d) => d.kind == SvgAnimateDiagnosticKind.neverChanges,
      );
      expect(still.message, contains('"d"'));
      expect(still.message, contains('authored'));
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
