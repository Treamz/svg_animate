import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/svg_animate.dart';

const String _spinner = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
  <rect width="100" height="100" fill="#ff0000" opacity="0">
    <animate attributeName="opacity" from="0" to="1" dur="1s" repeatCount="indefinite"/>
  </rect>
</svg>
''';

const String _static = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
  <rect width="100" height="100" fill="#ff0000"/>
</svg>
''';

void main() {
  test('compiles an animation and reports what it costs', () async {
    final AnimatedSvgFrames frames = await compileAnimatedSvg(_spinner, frameRate: 4);

    expect(frames.frameCount, 4);
    expect(frames.duration, const Duration(seconds: 1));
    expect(frames.loops, isTrue);
    expect(frames.isAnimated, isTrue);
    expect(frames.compiledByteSize, greaterThan(0));
  });

  test('compiles an SVG without animation to a single frame', () async {
    final AnimatedSvgFrames frames = await compileAnimatedSvg(_static);

    expect(frames.frameCount, 1);
    expect(frames.isAnimated, isFalse);
  });

  test('honors the frame rate and the ceiling on frames', () async {
    expect((await compileAnimatedSvg(_spinner, frameRate: 20)).frameCount, 20);
    expect((await compileAnimatedSvg(_spinner, frameRate: 20, maxFrames: 5)).frameCount, 5);
  });
}
