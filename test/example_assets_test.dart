import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/svg_animate.dart';

/// Every SVG the example ships is what the live demo shows, and a sample that
/// has quietly stopped animating looks exactly like one that has not started:
/// a still picture and no error. These compile each of them and insist there is
/// something to play and nothing to report.
///
/// A sample is also the one place the package makes a promise it cannot take
/// back — somebody looking at the demo is deciding whether their own file will
/// work — so a diagnostic here is a failure rather than a note.
void main() {
  final List<File> assets =
      Directory(
          'example/assets',
        ).listSync().whereType<File>().where((File file) => file.path.endsWith('.svg')).toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));

  test('there are samples to check', () {
    expect(assets, isNotEmpty);
  });

  for (final File asset in assets) {
    final String name = asset.uri.pathSegments.last;

    test('$name animates, and reports nothing wrong', () async {
      final AnimatedSvgFrames frames = await compileAnimatedSvg(asset.readAsStringSync());

      expect(
        frames.diagnostics.map((SvgAnimateDiagnostic d) => d.message),
        isEmpty,
        reason: 'a sample is meant to be one of the things that work',
      );
      expect(frames.isAnimated, isTrue);
      expect(
        frames.distinctFrameCount,
        greaterThan(1),
        reason: 'frames that are all the same picture are a still SVG with a ticker',
      );

      // Not an assertion about what is right, only a floor low enough that
      // anything under it is a sample that has become too expensive to show on
      // a page that loads several of them at once.
      expect(frames.compiledByteSize, lessThan(2 << 20));
    });
  }
}
