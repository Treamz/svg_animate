import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/src/animation/document.dart';
import 'package:svg_animate/src/animation/frames.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart' as vg;

void main() {
  test('the README demo animates through this package', () async {
    final String source = File('doc/demo.svg').readAsStringSync();
    final AnimatedSvgDocument document = AnimatedSvgDocument.parse(source);

    expect(document.isAnimated, isTrue);
    expect(document.loops, isTrue);
    // Every animation in the demo divides this period, so the flipbook loops
    // seamlessly rather than falling back to the longest single iteration.
    expect(document.duration, const Duration(milliseconds: 2400));

    final AnimatedSvgFrames frames = await compileAnimatedSvgFrames(
      source,
      theme: const vg.SvgTheme(),
      colorMapper: null,
      frameRate: 10,
    );
    expect(frames.frames.length, 24);
    expect(
      frames.frames.first.buffer.asUint8List(),
      isNot(frames.frames[12].buffer.asUint8List()),
      reason: 'the demo should look different halfway through',
    );
  });
}
