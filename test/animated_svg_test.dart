import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:svg_animate/svg_animate.dart';
import 'package:svg_animate/src/animation/frames.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_graphics/vector_graphics.dart';

const String _spinner = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
  <rect width="100" height="100" fill="#ff0000" opacity="0">
    <animate attributeName="opacity" from="0" to="1" dur="1s" repeatCount="indefinite"/>
  </rect>
</svg>
''';

const String _oneShot = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
  <rect width="100" height="100" fill="#ff0000" opacity="0">
    <animate attributeName="opacity" from="0" to="1" dur="1s" fill="freeze"/>
  </rect>
</svg>
''';

const String _static = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
  <rect width="100" height="100" fill="#ff0000"/>
</svg>
''';

/// A loader that does not provide its markup until [completer] is completed,
/// so that tests can observe the widget while it is still loading.
class _PendingLoader extends SvgSourceLoader<void> {
  const _PendingLoader(this.source, this.completer);

  final String source;
  final Completer<void> completer;

  @override
  Future<void> prepareMessage(BuildContext? context) => completer.future;

  @override
  String provideSvg(void message) => source;
}

/// The loader of the vector graphic currently on screen.
AnimatedSvgFrameLoader _frameLoader(WidgetTester tester) =>
    tester.widget<VectorGraphic>(find.byType(VectorGraphic)).loader as AnimatedSvgFrameLoader;

int _frameIndex(WidgetTester tester) => _frameLoader(tester).frameIndex;

void main() {
  setUp(() {
    svgAnimateCache.clear();
  });

  testWidgets('compiles one frame per tick of the frame rate', (WidgetTester tester) async {
    await tester.pumpWidget(
      AnimatedSvgPicture.string(_spinner, frameRate: 4, width: 100, height: 100),
    );
    await tester.pump();

    expect(_frameLoader(tester).frames.frameCount, 4);
    expect(_frameLoader(tester).frames.duration, const Duration(seconds: 1));
    expect(_frameLoader(tester).frames.loops, isTrue);
  });

  testWidgets('advances through frames as time passes', (WidgetTester tester) async {
    await tester.pumpWidget(
      AnimatedSvgPicture.string(_spinner, frameRate: 4, width: 100, height: 100),
    );
    await tester.pump();
    expect(_frameIndex(tester), 0);

    await tester.pump(const Duration(milliseconds: 250));
    expect(_frameIndex(tester), 1);

    await tester.pump(const Duration(milliseconds: 500));
    expect(_frameIndex(tester), 3);
  });

  testWidgets('loops back to the first frame', (WidgetTester tester) async {
    var completed = 0;
    await tester.pumpWidget(
      AnimatedSvgPicture.string(
        _spinner,
        frameRate: 4,
        width: 100,
        height: 100,
        onCompleted: () => completed += 1,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
    expect(_frameIndex(tester), 3);

    await tester.pump(const Duration(milliseconds: 250));
    expect(_frameIndex(tester), 0);
    expect(completed, 1);
  });

  testWidgets('holds the last frame when it does not repeat', (WidgetTester tester) async {
    var completed = 0;
    await tester.pumpWidget(
      AnimatedSvgPicture.string(
        _oneShot,
        frameRate: 4,
        repeat: false,
        width: 100,
        height: 100,
        onCompleted: () => completed += 1,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(_frameIndex(tester), 3);
    expect(completed, 1);
  });

  testWidgets('renders an SVG without animation as a single frame', (WidgetTester tester) async {
    await tester.pumpWidget(AnimatedSvgPicture.string(_static, width: 100, height: 100));
    await tester.pump();

    expect(_frameLoader(tester).frames.frameCount, 1);
    expect(_frameLoader(tester).frames.isAnimated, isFalse);
    // No ticker should be running, so the test can settle.
    await tester.pumpAndSettle();
  });

  testWidgets('shows the placeholder until the animation is compiled', (WidgetTester tester) async {
    final completer = Completer<void>();
    await tester.pumpWidget(
      AnimatedSvgPicture(
        _PendingLoader(_spinner, completer),
        frameRate: 4,
        width: 100,
        height: 100,
        placeholderBuilder: (BuildContext context) =>
            const Text('loading', textDirection: TextDirection.ltr),
      ),
    );

    expect(find.text('loading'), findsOneWidget);
    expect(find.byType(VectorGraphic), findsNothing);

    completer.complete();
    // One frame for the load to complete, and one to rebuild with the result.
    await tester.pump();
    await tester.pump();

    expect(find.text('loading'), findsNothing);
    expect(find.byType(VectorGraphic), findsOneWidget);
  });

  testWidgets('reports malformed markup through the error builder', (WidgetTester tester) async {
    await tester.pumpWidget(
      AnimatedSvgPicture.string(
        '<svg><rect></svg>',
        width: 100,
        height: 100,
        errorBuilder: (BuildContext context, Object error, StackTrace stackTrace) =>
            const Text('broken', textDirection: TextDirection.ltr),
      ),
    );
    await tester.pump();

    expect(find.text('broken'), findsOneWidget);
  });

  testWidgets('compiles each animation only once', (WidgetTester tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          children: <Widget>[
            AnimatedSvgPicture.string(_spinner, frameRate: 4, width: 10, height: 10),
            AnimatedSvgPicture.string(_spinner, frameRate: 4, width: 10, height: 10),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(svgAnimateCache.count, 1);
    final List<VectorGraphic> graphics = tester
        .widgetList<VectorGraphic>(find.byType(VectorGraphic))
        .toList();
    expect(
      identical(
        (graphics.first.loader as AnimatedSvgFrameLoader).frames,
        (graphics.last.loader as AnimatedSvgFrameLoader).frames,
      ),
      isTrue,
    );
  });

  testWidgets('stops repeating when repeat is turned off', (WidgetTester tester) async {
    final controller = AnimatedSvgController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      AnimatedSvgPicture.string(
        _spinner,
        frameRate: 4,
        width: 100,
        height: 100,
        controller: controller,
      ),
    );
    await tester.pump();
    expect(controller.isPlaying, isTrue);

    await tester.pumpWidget(
      AnimatedSvgPicture.string(
        _spinner,
        frameRate: 4,
        repeat: false,
        width: 100,
        height: 100,
        controller: controller,
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.isPlaying, isFalse);
    expect(controller.progress.value, 1.0);
  });

  testWidgets('recompiles when the frame rate changes', (WidgetTester tester) async {
    await tester.pumpWidget(
      AnimatedSvgPicture.string(_spinner, frameRate: 4, width: 100, height: 100),
    );
    await tester.pump();
    expect(_frameLoader(tester).frames.frameCount, 4);

    await tester.pumpWidget(
      AnimatedSvgPicture.string(_spinner, frameRate: 8, width: 100, height: 100),
    );
    await tester.pump();
    expect(_frameLoader(tester).frames.frameCount, 8);
  });

  testWidgets('follows the document when repeat is not given', (WidgetTester tester) async {
    // The spinner repeats forever, so it loops.
    await tester.pumpWidget(
      AnimatedSvgPicture.string(_spinner, frameRate: 4, width: 100, height: 100),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
    expect(_frameIndex(tester), 3);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_frameIndex(tester), 0, reason: 'an indefinite animation should loop');

    // The one-shot animation ends, so it plays once and holds its last frame.
    await tester.pumpWidget(
      AnimatedSvgPicture.string(_oneShot, frameRate: 4, width: 100, height: 100),
    );
    await tester.pumpAndSettle();
    expect(_frameIndex(tester), 3, reason: 'an animation that ends should not loop');
  });

  testWidgets('keeps playing when a reload resolves to the same frames', (
    WidgetTester tester,
  ) async {
    final Directory directory = Directory.systemTemp.createTempSync('flutter_svg_test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/spinner.svg')..writeAsStringSync(_spinner);

    await tester.pumpWidget(
      AnimatedSvgPicture.file(File(file.path), frameRate: 4, width: 100, height: 100),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_frameIndex(tester), 2);

    // A rebuild that constructs an equivalent loader must neither recompile the
    // animation nor send playback back to the start.
    await tester.pumpWidget(
      AnimatedSvgPicture.file(File(file.path), frameRate: 4, width: 100, height: 100),
    );
    await tester.pump();

    expect(_frameIndex(tester), 2);
    expect(svgAnimateCache.count, 1);
  });

  group('AnimatedSvgController', () {
    testWidgets('pauses, seeks, and resumes', (WidgetTester tester) async {
      final controller = AnimatedSvgController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        AnimatedSvgPicture.string(
          _spinner,
          frameRate: 4,
          width: 100,
          height: 100,
          controller: controller,
        ),
      );
      await tester.pump();
      expect(controller.isReady, isTrue);
      expect(controller.isPlaying, isTrue);
      expect(controller.duration, const Duration(seconds: 1));

      controller.pause();
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller.isPlaying, isFalse);
      expect(_frameIndex(tester), 0);

      controller.seek(0.5);
      await tester.pump();
      expect(_frameIndex(tester), 2);
      expect(controller.position, const Duration(milliseconds: 500));

      controller.play();
      // The first frame after starting only starts the ticker.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(controller.isPlaying, isTrue);
      expect(_frameIndex(tester), 3);

      controller.stop();
      await tester.pump();
      expect(_frameIndex(tester), 0);
    });

    testWidgets('honors requests made before the animation loads', (WidgetTester tester) async {
      final controller = AnimatedSvgController();
      addTearDown(controller.dispose);
      controller.pause();
      controller.seek(0.5);

      await tester.pumpWidget(
        AnimatedSvgPicture.string(
          _spinner,
          frameRate: 4,
          width: 100,
          height: 100,
          controller: controller,
        ),
      );
      await tester.pump();

      expect(controller.isPlaying, isFalse);
      expect(_frameIndex(tester), 2);
    });

    testWidgets('honors a seekTo issued before the animation loads', (WidgetTester tester) async {
      final controller = AnimatedSvgController();
      addTearDown(controller.dispose);
      controller.pause();
      controller.seekTo(const Duration(milliseconds: 500));

      await tester.pumpWidget(
        AnimatedSvgPicture.string(
          _spinner,
          frameRate: 4,
          width: 100,
          height: 100,
          controller: controller,
        ),
      );
      await tester.pump();

      expect(controller.position, const Duration(milliseconds: 500));
      expect(_frameIndex(tester), 2);
    });

    testWidgets('exposes a progress animation that works before loading', (
      WidgetTester tester,
    ) async {
      final controller = AnimatedSvgController();
      addTearDown(controller.dispose);
      // Captured before the picture exists, as a caller building a widget tree
      // in one pass would.
      final Animation<double> progress = controller.progress;
      var ticks = 0;
      progress.addListener(() => ticks += 1);

      await tester.pumpWidget(
        AnimatedSvgPicture.string(
          _spinner,
          frameRate: 4,
          width: 100,
          height: 100,
          controller: controller,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(identical(controller.progress, progress), isTrue);
      expect(ticks, greaterThan(0));
      expect(progress.value, greaterThan(0));
    });

    testWidgets('survives being disposed while the picture is still mounted', (
      WidgetTester tester,
    ) async {
      final controller = AnimatedSvgController();
      await tester.pumpWidget(
        AnimatedSvgPicture.string(
          _spinner,
          frameRate: 4,
          width: 100,
          height: 100,
          controller: controller,
        ),
      );
      await tester.pump();

      controller.dispose();
      // The picture keeps playing; the controller simply stops reporting.
      await tester.pump(const Duration(milliseconds: 250));
      expect(_frameIndex(tester), 1);
    });

    testWidgets('does not start playing when autoPlay is false', (WidgetTester tester) async {
      await tester.pumpWidget(
        AnimatedSvgPicture.string(_spinner, frameRate: 4, autoPlay: false, width: 100, height: 100),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750));

      expect(_frameIndex(tester), 0);
    });
  });
}
