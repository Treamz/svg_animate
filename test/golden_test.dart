@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/svg_animate.dart';

/// Renders frames and compares them to a stored image.
///
/// Everything else in this suite reads the markup a frame was compiled from,
/// which is where the values are but not where the drawing is. A rounded
/// rectangle whose corner radius outgrew its width drew as a bow tie in the
/// example and in the README image for months: every attribute was the one it
/// should have been, and the picture was still wrong. Only pixels catch that.
///
/// **macOS only, deliberately.** Antialiasing along a curve differs between
/// platforms, so an image stored from one of them fails on another for reasons
/// that have nothing to do with this package. CI runs the suite on macOS as
/// well as on Linux, so these are still checked on every pull request; they are
/// skipped on Linux rather than compared loosely, because a comparison loose
/// enough to survive a different renderer is loose enough to miss a thin shape
/// going missing.
///
/// Regenerate with `flutter test --update-goldens test/golden_test.dart`, and
/// look at what changed before committing it.

/// The fixtures are the example's own assets, so that what is guarded is what
/// somebody actually looks at rather than a shape invented for the test.
String asset(String name) => File('example/assets/$name.svg').readAsStringSync();

/// Draws [markup] at [progress] through its animation and compares it.
///
/// Playback is never started: the controller is seeked instead, so the frame
/// is chosen rather than raced for.
Future<void> expectFrame(
  WidgetTester tester,
  String markup,
  double progress,
  String golden, {
  Size size = const Size(240, 80),
}) async {
  final AnimatedSvgController controller = AnimatedSvgController();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(
          child: ColoredBox(
            color: const Color(0xFFFFFFFF),
            child: SizedBox.fromSize(
              size: size,
              child: AnimatedSvgPicture.string(
                markup,
                width: size.width,
                height: size.height,
                controller: controller,
                autoPlay: false,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // Compiling happens before anything is drawn, and there is no ticker to wait
  // on because playback was never started.
  await tester.pumpAndSettle();
  controller.seek(progress);
  await tester.pumpAndSettle();

  await expectLater(find.byType(RepaintBoundary).last, matchesGoldenFile('goldens/$golden.png'));
}

void main() {
  group('a rounded bar that grows from nothing', () {
    // The regression this suite exists for. At zero width the corner radius is
    // larger than the rect it rounds, and the rounded ends crossed over one
    // another into a bow tie at the left edge.
    testWidgets('draws nothing but its track at the start', (WidgetTester tester) async {
      await expectFrame(tester, asset('progress'), 0, 'progress_start');
    });

    // Part way in, the radius is clamped to half the width rather than to zero,
    // which is the arithmetic rather than the special case.
    testWidgets('draws a bar narrower than its own corner radius', (WidgetTester tester) async {
      await expectFrame(tester, asset('progress'), 0.15, 'progress_narrow');
    });

    testWidgets('draws fully rounded once it is wide enough', (WidgetTester tester) async {
      await expectFrame(tester, asset('progress'), 1, 'progress_full');
    });
  });

  group('the other shapes the example draws', () {
    testWidgets('spinner', (WidgetTester tester) async {
      await expectFrame(tester, asset('spinner'), 0.25, 'spinner', size: const Size(120, 120));
    });

    testWidgets('pulse', (WidgetTester tester) async {
      await expectFrame(tester, asset('pulse'), 0.25, 'pulse', size: const Size(120, 120));
    });

    testWidgets('orbit', (WidgetTester tester) async {
      await expectFrame(tester, asset('orbit'), 0.25, 'orbit', size: const Size(120, 120));
    });
  });
}
