import 'package:flutter/widgets.dart';

import 'animation/cache.dart';
import 'animation/frames.dart';
import 'color_mapper.dart';
import 'loaders.dart';

/// Compiles an animation into the shared cache before anything shows it.
///
/// Compiling is the expensive part of drawing an animated SVG, and it happens
/// when the picture is first built: a large document takes long enough that
/// there is a placeholder, then a still first frame, and only then movement.
/// Doing it on the screen before, where there is time to spare, means the
/// picture is there the moment the widget is.
///
/// ```dart
/// @override
/// void didChangeDependencies() {
///   super.didChangeDependencies();
///   precacheAnimatedSvg(const SvgAnimateAssetLoader('assets/intro.svg'), context);
/// }
/// ```
///
/// [context] is what a loader resolves an enclosing `DefaultSvgTheme` and
/// `DefaultAssetBundle` against, so pass the one the picture will be built
/// under. Passing null is fine for a loader that needs neither, such as one
/// reading a string or a file.
///
/// [frameRate] and [maxFrames] must match what the picture will be built with,
/// because an animation compiled at one frame rate is not the animation
/// compiled at another and is cached separately.
///
/// Returns the compiled frames, which can say what the animation cost:
///
/// ```dart
/// final AnimatedSvgFrames frames = await precacheAnimatedSvg(loader, context);
/// debugPrint('${frames.frameCount} frames, ${frames.compiledByteSize} bytes');
/// ```
///
/// Reading a source that is not there, or one that is not well formed XML,
/// throws here rather than when the picture is built. Catch it if a failed
/// precache should not be a failed screen; the picture will report the same
/// error again through its own `errorBuilder` when it is built.
///
/// Precaching the same animation twice compiles it once. An animation the cache
/// has already evicted is compiled again, so precache near where it is shown
/// rather than at the start of the app.
Future<AnimatedSvgFrames> precacheAnimatedSvg(
  SvgSourceLoader<Object?> loader,
  BuildContext? context, {
  double frameRate = defaultAnimationFrameRate,
  int maxFrames = defaultMaxAnimationFrames,
}) {
  assert(frameRate > 0);
  assert(maxFrames > 0);
  // The same key the widget will look it up under, built by the same class, so
  // that the two cannot drift apart into a precache that silently does nothing.
  final key = AnimatedSvgCacheKey(loader.cacheKey(context), frameRate, maxFrames);
  return svgAnimateCache.putIfAbsent(
    key,
    // Chained rather than awaited. A loader reading a string or bytes completes
    // synchronously, and awaiting a synchronous future runs what follows before
    // this has been wrapped in a future that can hold an error: a document that
    // fails to parse then escapes as an unhandled exception instead of
    // completing this one. `putIfAbsent` wraps the chain in `Future.sync`,
    // which is what catches it.
    () => loader
        .loadSvgSource(context)
        .then(
          (SvgSource source) => compileAnimatedSvgFrames(
            source.xml,
            theme: source.theme.toVgTheme(),
            colorMapper: toVgColorMapper(source.colorMapper),
            frameRate: frameRate,
            maxFrames: maxFrames,
            debugName: loader.toString(),
          ),
        ),
  );
}
