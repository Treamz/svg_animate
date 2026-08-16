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

  test('compiles a single frame that still knows the whole animation', () async {
    // What a picture shows while the rest of its frames are still being
    // compiled. It has to carry the real duration and loop flag, since those
    // decide how the full animation will be played once it arrives.
    final AnimatedSvgFrames poster = await compileAnimatedSvg(_spinner, maxFrames: 1);

    expect(poster.frameCount, 1);
    expect(poster.duration, const Duration(seconds: 1));
    expect(poster.loops, isTrue);
    expect(poster.isAnimated, isFalse, reason: 'one frame cannot be played');

    // It is the animation at time zero, not some other frame of it.
    final AnimatedSvgFrames full = await compileAnimatedSvg(_spinner, frameRate: 4);
    expect(poster.frameAt(0).buffer.asUint8List(), full.frameAt(0).buffer.asUint8List());
  });

  test('honors the frame rate and the ceiling on frames', () async {
    expect((await compileAnimatedSvg(_spinner, frameRate: 20)).frameCount, 20);
    expect((await compileAnimatedSvg(_spinner, frameRate: 20, maxFrames: 5)).frameCount, 5);
  });
}
