import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/svg_animate.dart';

Future<List<SvgAnimateDiagnostic>> diagnose(String svg, {int maxFrames = 300}) async {
  final AnimatedSvgFrames frames = await compileAnimatedSvg(svg, maxFrames: maxFrames);
  return frames.diagnostics;
}

Set<SvgAnimateDiagnosticKind> kinds(List<SvgAnimateDiagnostic> diagnostics) =>
    diagnostics.map((SvgAnimateDiagnostic d) => d.kind).toSet();

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
