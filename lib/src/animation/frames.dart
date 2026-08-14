import 'package:flutter/foundation.dart' hide compute;
import 'package:flutter/widgets.dart';
import 'package:vector_graphics/vector_graphics.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart' as vg;

import '../utilities/compute.dart';
import 'document.dart';

/// The default number of frames compiled per second of animation.
const double defaultAnimationFrameRate = 60;

/// The default ceiling on how many frames a single animation is compiled into.
///
/// Long animations are sampled at a lower rate rather than compiling an
/// unbounded number of frames, which would take an unbounded amount of memory.
const int defaultMaxAnimationFrames = 300;

/// An animated SVG that has been compiled into one static vector graphic per
/// frame.
///
/// The frames are compiled once, when the animation is first loaded, and then
/// played back in order. Compiling ahead of time keeps the per frame cost to
/// decoding an already encoded picture.
@immutable
class AnimatedSvgFrames {
  /// Creates a set of compiled frames.
  const AnimatedSvgFrames({required this.frames, required this.duration, required this.loops});

  /// The encoded vector graphic for each frame, in order.
  ///
  /// Always contains at least one entry; an SVG with no animation compiles to a
  /// single frame.
  final List<ByteData> frames;

  /// How long one pass through [frames] takes.
  final Duration duration;

  /// Whether playback should restart after the last frame.
  final bool loops;

  /// Whether there is anything to play.
  bool get isAnimated => frames.length > 1 && duration > Duration.zero;

  /// The frame to show at [progress] through the animation, from 0.0 to 1.0.
  int frameIndexAt(double progress) {
    if (frames.length <= 1) {
      return 0;
    }
    if (loops) {
      // The last frame ends just before the loop point, so the frame after it
      // is the first one again.
      final int index = (progress * frames.length).floor() % frames.length;
      return index < 0 ? index + frames.length : index;
    }
    return (progress.clamp(0.0, 1.0) * (frames.length - 1)).round();
  }
}

/// Compiles the animation in [source] into one vector graphic per frame.
///
/// The work happens in a background isolate on platforms that support them, in
/// the same way that decoding a static SVG does.
Future<AnimatedSvgFrames> compileAnimatedSvgFrames(
  String source, {
  required vg.SvgTheme theme,
  required vg.ColorMapper? colorMapper,
  double frameRate = defaultAnimationFrameRate,
  int maxFrames = defaultMaxAnimationFrames,
  String debugName = 'Animated SVG loader',
}) {
  assert(frameRate > 0);
  assert(maxFrames > 0);
  return compute(
    (String source) {
      final document = AnimatedSvgDocument.parse(source);
      final Duration duration = document.duration;
      final int frameCount = _frameCount(duration, frameRate, maxFrames);
      final frames = <ByteData>[
        for (var index = 0; index < frameCount; index += 1)
          vg
              .encodeSvg(
                xml: document.sampleAt(_frameTime(duration, index, frameCount, document.loops)),
                theme: theme,
                colorMapper: colorMapper,
                debugName: debugName,
                enableClippingOptimizer: false,
                enableMaskingOptimizer: false,
                enableOverdrawOptimizer: false,
              )
              .buffer
              .asByteData(),
      ];
      return AnimatedSvgFrames(frames: frames, duration: duration, loops: document.loops);
    },
    source,
    debugLabel: 'Compile animated SVG',
  );
}

int _frameCount(Duration duration, double frameRate, int maxFrames) {
  if (duration <= Duration.zero) {
    return 1;
  }
  final double seconds = duration.inMicroseconds / Duration.microsecondsPerSecond;
  return (seconds * frameRate).round().clamp(1, maxFrames);
}

Duration _frameTime(Duration duration, int index, int frameCount, bool loops) {
  if (frameCount <= 1) {
    return Duration.zero;
  }
  // A looping animation must not repeat its first frame at the end of the loop,
  // so its frames sit on the half open interval [0, duration).
  final int divisor = loops ? frameCount : frameCount - 1;
  return Duration(microseconds: duration.inMicroseconds * index ~/ divisor);
}

/// A [BytesLoader] that serves one already compiled frame of an animation.
///
/// The cache key pairs the frame index with the identity of the compiled
/// animation, so the renderer's picture cache reuses a frame's decoded picture
/// whenever the animation loops back around to it.
@immutable
class AnimatedSvgFrameLoader extends BytesLoader {
  /// Serves frame [frameIndex] of [frames].
  const AnimatedSvgFrameLoader(this.frames, this.frameIndex);

  /// The compiled animation this frame belongs to.
  final AnimatedSvgFrames frames;

  /// The index of the frame to serve.
  final int frameIndex;

  @override
  Future<ByteData> loadBytes(BuildContext? context) =>
      SynchronousFuture<ByteData>(frames.frames[frameIndex]);

  @override
  Object cacheKey(BuildContext? context) => _AnimatedSvgFrameKey(frames, frameIndex);

  @override
  bool operator ==(Object other) =>
      other is AnimatedSvgFrameLoader &&
      identical(other.frames, frames) &&
      other.frameIndex == frameIndex;

  @override
  int get hashCode => Object.hash(identityHashCode(frames), frameIndex);

  @override
  String toString() => 'AnimatedSvgFrameLoader(frame $frameIndex of ${frames.frames.length})';
}

@immutable
class _AnimatedSvgFrameKey {
  const _AnimatedSvgFrameKey(this.frames, this.frameIndex);

  final AnimatedSvgFrames frames;
  final int frameIndex;

  @override
  bool operator ==(Object other) =>
      other is _AnimatedSvgFrameKey &&
      identical(other.frames, frames) &&
      other.frameIndex == frameIndex;

  @override
  int get hashCode => Object.hash(identityHashCode(frames), frameIndex);
}
