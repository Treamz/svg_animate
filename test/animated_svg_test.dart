import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// The same one-shot animation, twice as long.
///
/// Used as the edit: a duration is the cheapest thing to tell apart from the
/// outside without looking at pixels.
const String _oneShotLonger = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
  <rect width="100" height="100" fill="#ff0000" opacity="0">
    <animate attributeName="opacity" from="0" to="1" dur="2s" fill="freeze"/>
  </rect>
</svg>
''';

const String _static = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
  <rect width="100" height="100" fill="#ff0000"/>
</svg>
''';

/// A bundle whose asset can be edited, the way a file on disk can be.
class _EditableBundle extends CachingAssetBundle {
  _EditableBundle(this.markup);

  String markup;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(utf8.encode(markup)));
}

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

  testWidgets('skips the first-frame pass when the animation is already cached', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      AnimatedSvgPicture.string(_spinner, frameRate: 4, width: 100, height: 100),
    );
    await tester.pump();
    expect(_frameLoader(tester).frames.frameCount, 4);

    // A second widget on the same animation has nothing to wait for, so it must
    // not flash a single frame on the way.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      AnimatedSvgPicture.string(_spinner, frameRate: 4, width: 100, height: 100),
    );
    await tester.pump();
    expect(_frameLoader(tester).frames.frameCount, 4);
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

  group('memory pressure', () {
    /// What the engine sends when the system wants memory back.
    Future<void> squeeze(WidgetTester tester) {
      return tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.system.name,
        const JSONMessageCodec().encodeMessage(<String, dynamic>{'type': 'memoryPressure'}),
        (ByteData? _) {},
      );
    }

    testWidgets('lets the cache go', (WidgetTester tester) async {
      // Flutter throws away every decoded image at this point. Compiled
      // animations are the larger half of what this package holds, and nothing
      // was letting go of them.
      await tester.pumpWidget(
        AnimatedSvgPicture.string(_spinner, frameRate: 4, width: 100, height: 100),
      );
      await tester.pump();
      expect(svgAnimateCache.count, 1);

      await squeeze(tester);

      expect(svgAnimateCache.count, 0);
    });

    testWidgets('and the picture already on screen goes on playing', (WidgetTester tester) async {
      // Nothing is lost by letting go: a picture holds its own frames, so it
      // only pays again if it is rebuilt.
      await tester.pumpWidget(
        AnimatedSvgPicture.string(_spinner, frameRate: 4, width: 100, height: 100),
      );
      await tester.pump();

      await squeeze(tester);
      await tester.pump(const Duration(milliseconds: 250));

      expect(_frameIndex(tester), 1);
    });
  });

  group('a hot reload', () {
    Widget picture(_EditableBundle bundle) => DefaultAssetBundle(
      bundle: bundle,
      child: AnimatedSvgPicture.asset('a.svg', frameRate: 4, width: 100, height: 100),
    );

    testWidgets('shows an SVG that has been edited since it was compiled', (
      WidgetTester tester,
    ) async {
      final bundle = _EditableBundle(_oneShot);
      await tester.pumpWidget(picture(bundle));
      await tester.pump();
      expect(_frameLoader(tester).frames.duration, const Duration(seconds: 1));

      bundle.markup = _oneShotLonger;
      bundle.clear();
      // Started rather than awaited: the future it returns completes at the end
      // of a frame, and in a test nothing pumps one while the await is holding.
      final Future<void> reloaded = tester.binding.reassembleApplication();
      await tester.pump();
      await reloaded;
      await tester.pump();

      expect(_frameLoader(tester).frames.duration, const Duration(seconds: 2));
    });

    testWidgets('which a rebuild on its own does not', (WidgetTester tester) async {
      // The other half, and the reason the one above is worth having: the key
      // an animation is cached under is made of the asset's name and not of its
      // contents, so nothing about rebuilding notices that the file changed.
      final bundle = _EditableBundle(_oneShot);
      await tester.pumpWidget(picture(bundle));
      await tester.pump();

      bundle.markup = _oneShotLonger;
      bundle.clear();
      await tester.pumpWidget(picture(bundle));
      await tester.pump();

      expect(_frameLoader(tester).frames.duration, const Duration(seconds: 1));
    });
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

  group('playback speed', () {
    testWidgets('scales how long a pass takes, and may be set before loading', (
      WidgetTester tester,
    ) async {
      final controller = AnimatedSvgController();
      addTearDown(controller.dispose);
      controller.speed = 2;

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

      expect(controller.speed, 2);
      expect(controller.duration, const Duration(milliseconds: 500));

      // A quarter of a second used to be a quarter of the way through.
      await tester.pump(const Duration(milliseconds: 250));
      expect(_frameIndex(tester), 2);
    });

    testWidgets('takes effect on an animation that is already running', (
      WidgetTester tester,
    ) async {
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
      await tester.pump(const Duration(milliseconds: 250));
      expect(_frameIndex(tester), 1);

      // A controller reads its duration when it is told to run, so this only
      // lands because the speed setter tells it again.
      controller.speed = 2;
      // Telling the playback controller to run again restarts its ticker, and
      // the frame that restarts it carries no elapsed time, the same as the
      // frame after `play`.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));
      expect(_frameIndex(tester), 2);
    });

    testWidgets('does not recompile the animation', (WidgetTester tester) async {
      // The point of doing it this way: the frames are already compiled and
      // only how long playback takes to walk through them changes.
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
      final AnimatedSvgFrames before = _frameLoader(tester).frames;

      controller.speed = 3;
      await tester.pump();

      expect(identical(_frameLoader(tester).frames, before), isTrue);
      expect(svgAnimateCache.count, 1);
    });

    testWidgets('refuses a speed that is not positive', (WidgetTester tester) async {
      final controller = AnimatedSvgController();
      addTearDown(controller.dispose);

      expect(() => controller.speed = 0, throwsAssertionError);
      expect(() => controller.speed = -2, throwsAssertionError);
    });
  });

  group('playing backwards', () {
    testWidgets('runs back towards the first frame and stops there', (WidgetTester tester) async {
      final controller = AnimatedSvgController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        AnimatedSvgPicture.string(
          _oneShot,
          frameRate: 4,
          repeat: false,
          width: 100,
          height: 100,
          controller: controller,
          autoPlay: false,
        ),
      );
      await tester.pump();
      controller.seek(1);
      await tester.pump();
      expect(_frameIndex(tester), 3);

      controller.reverse();
      expect(controller.isReversed, isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_frameIndex(tester), 2);

      await tester.pumpAndSettle();
      expect(_frameIndex(tester), 0);
      expect(controller.isPlaying, isFalse);
    });

    testWidgets('reports the end of the pass once, not on every frame of it', (
      WidgetTester tester,
    ) async {
      // The regression this guards. A frame index that moves down is what marks
      // the end of a loop, and every tick of a backwards pass moves it down, so
      // without the direction in that test `onCompleted` fires on all of them.
      var completed = 0;
      final controller = AnimatedSvgController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        AnimatedSvgPicture.string(
          _oneShot,
          frameRate: 4,
          repeat: false,
          width: 100,
          height: 100,
          controller: controller,
          autoPlay: false,
          onCompleted: () => completed += 1,
        ),
      );
      await tester.pump();
      controller.seek(1);
      await tester.pump();
      // Seeking a one-shot animation to its last frame is arriving at its end
      // in its own right, and is reported. What this test is about starts here.
      completed = 0;

      controller.reverse();
      await tester.pumpAndSettle();

      expect(_frameIndex(tester), 0);
      expect(completed, 1);
    });

    testWidgets('starts from the last frame when it is already at the first', (
      WidgetTester tester,
    ) async {
      // The mirror of [AnimatedSvgController.play] starting again from the
      // beginning once an animation has run to its end.
      final controller = AnimatedSvgController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        AnimatedSvgPicture.string(
          _oneShot,
          frameRate: 4,
          repeat: false,
          width: 100,
          height: 100,
          controller: controller,
          autoPlay: false,
        ),
      );
      await tester.pump();
      expect(_frameIndex(tester), 0);

      controller.reverse();
      await tester.pump();
      expect(_frameIndex(tester), 3);
    });

    testWidgets('keeps looping an animation that repeats', (WidgetTester tester) async {
      var completed = 0;
      final controller = AnimatedSvgController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        AnimatedSvgPicture.string(
          _spinner,
          frameRate: 4,
          width: 100,
          height: 100,
          controller: controller,
          autoPlay: false,
          onCompleted: () => completed += 1,
        ),
      );
      await tester.pump();

      controller.reverse();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_frameIndex(tester), 2);

      // Past the start, where `repeat` would have been no use: it only ever
      // runs forwards, so the next pass is started by hand.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.isPlaying, isTrue);
      expect(_frameIndex(tester), 3);
      expect(completed, 1);
    });

    testWidgets('says so when the animation runs out on its own', (WidgetTester tester) async {
      // `isPlaying` went to false and nothing told anybody, so a play button
      // driven by the controller went on showing a pause icon.
      var notifications = 0;
      final controller = AnimatedSvgController();
      addTearDown(controller.dispose);
      controller.addListener(() => notifications += 1);

      await tester.pumpWidget(
        AnimatedSvgPicture.string(
          _oneShot,
          frameRate: 4,
          repeat: false,
          width: 100,
          height: 100,
          controller: controller,
        ),
      );
      await tester.pump();
      final int whilePlaying = notifications;

      await tester.pumpAndSettle();

      expect(controller.isPlaying, isFalse);
      expect(notifications, greaterThan(whilePlaying));
    });

    testWidgets('stop leaves playback pointing forwards again', (WidgetTester tester) async {
      final controller = AnimatedSvgController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        AnimatedSvgPicture.string(
          _spinner,
          frameRate: 4,
          width: 100,
          height: 100,
          controller: controller,
          autoPlay: false,
        ),
      );
      await tester.pump();

      controller.reverse();
      await tester.pump();
      controller.stop();
      await tester.pump();
      expect(controller.isReversed, isFalse);

      controller.play();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(_frameIndex(tester), 1);
    });
  });
}
