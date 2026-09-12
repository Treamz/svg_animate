import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart' show DefaultSvgTheme, SvgTheme;
import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/svg_animate.dart';

const String spinning = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="10" height="10" fill="#f00">
    <animate attributeName="x" dur="1s" values="0;90" repeatCount="indefinite"/>
  </rect>
</svg>''';

/// Counts how many times it is asked for its source.
///
/// Counted in [prepareMessage], which is documented to run on the main isolate,
/// rather than in [provideSvg], which is meant to run in another one.
class _CountingLoader extends SvgSourceLoader<void> {
  _CountingLoader(this.markup);

  final String markup;

  /// Every context the source has been read under.
  ///
  /// A list rather than a counter because a loader is `@immutable`, and a
  /// final list that grows keeps that promise where a field that counts up
  /// would not.
  final List<BuildContext?> reads = <BuildContext?>[];

  @override
  Future<void> prepareMessage(BuildContext? context) {
    reads.add(context);
    return SynchronousFuture<void>(null);
  }

  @override
  String provideSvg(void message) => markup;
}

/// Builds the picture and waits for it to have loaded.
Future<void> show(
  WidgetTester tester,
  SvgSourceLoader<Object?> loader, {
  double frameRate = defaultAnimationFrameRate,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: AnimatedSvgPicture(
        loader,
        width: 100,
        height: 100,
        autoPlay: false,
        frameRate: frameRate,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // The cache is shared by the whole library, so a test that left something in
  // it would decide the result of the next one.
  setUp(svgAnimateCache.clear);
  tearDown(svgAnimateCache.clear);

  test('compiles the animation and reports what it cost', () async {
    final AnimatedSvgFrames frames = await precacheAnimatedSvg(
      const SvgAnimateStringLoader(spinning),
      null,
    );

    expect(frames.frameCount, greaterThan(1));
    expect(frames.isAnimated, isTrue);
    expect(frames.compiledByteSize, greaterThan(0));
  });

  test('puts it in the shared cache', () async {
    expect(svgAnimateCache.count, 0);
    await precacheAnimatedSvg(const SvgAnimateStringLoader(spinning), null);
    expect(svgAnimateCache.count, 1);
  });

  test('compiles once when asked twice', () async {
    final _CountingLoader loader = _CountingLoader(spinning);

    await precacheAnimatedSvg(loader, null);
    await precacheAnimatedSvg(loader, null);

    expect(loader.reads.length, 1);
  });

  // The point of the whole thing. The widget looks the animation up under a key
  // it builds itself; if precaching built a different one, it would appear to
  // work and quietly do nothing, because a cache miss looks exactly like never
  // having been asked.
  testWidgets('is what the picture then finds, without reading again', (WidgetTester tester) async {
    final _CountingLoader loader = _CountingLoader(spinning);
    await precacheAnimatedSvg(loader, null);
    expect(loader.reads.length, 1);

    await show(tester, loader);

    expect(loader.reads.length, 1, reason: 'the picture found it rather than compiling it again');
  });

  testWidgets('a picture built without one does read its source', (WidgetTester tester) async {
    // The other half: without precaching the count does move, so the test above
    // is measuring something.
    final _CountingLoader loader = _CountingLoader(spinning);
    await show(tester, loader);

    expect(loader.reads.length, 1);
  });

  testWidgets('a different frame rate is a different animation', (WidgetTester tester) async {
    // Frames compiled at 60 fps are not the frames compiled at 30, so they are
    // cached apart and precaching one does not stand in for the other.
    final _CountingLoader loader = _CountingLoader(spinning);
    await precacheAnimatedSvg(loader, null, frameRate: 60);

    await show(tester, loader, frameRate: 30);

    expect(loader.reads.length, 2);
    expect(svgAnimateCache.count, 2);
  });

  testWidgets('reads the theme from the context it is given', (WidgetTester tester) async {
    // An enclosing DefaultSvgTheme decides what `currentColor` compiles to, so
    // it has to be read where the picture will read it. Precaching against a
    // context inside the theme and then showing the picture inside the same
    // theme has to be one animation, not two.
    const SvgTheme green = SvgTheme(currentColor: Color(0xFF00FF00));
    final _CountingLoader loader = _CountingLoader(spinning);
    BuildContext? captured;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: DefaultSvgTheme(
          theme: green,
          child: Builder(
            builder: (BuildContext context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await precacheAnimatedSvg(loader, captured);
    expect(loader.reads.length, 1);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: DefaultSvgTheme(
          theme: green,
          child: AnimatedSvgPicture(loader, width: 100, height: 100, autoPlay: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loader.reads.length, 1, reason: 'the same theme is the same animation');
  });

  test('reports a broken document rather than hiding it until the picture is built', () async {
    await expectLater(
      precacheAnimatedSvg(const SvgAnimateStringLoader('<svg><unclosed></svg>'), null),
      throwsA(anything),
    );
    expect(svgAnimateCache.count, 0, reason: 'nothing half compiled is left behind');
  });
}
