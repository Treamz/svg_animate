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
///
/// Consecutive frames of one animation are largely identical: they describe the
/// same document with a handful of numbers changed, and anything the SVG
/// embeds, a raster image above all, is repeated in each of them verbatim. The
/// part they all begin with is therefore stored once and the frames keep only
/// what follows it, which for an SVG carrying embedded images is a fraction of
/// their size. A frame is put back together when it is asked for.
@immutable
class AnimatedSvgFrames {
  const AnimatedSvgFrames._({
    required Uint8List shared,
    required List<Uint8List> tails,
    required this.duration,
    required this.loops,
  }) : _shared = shared,
       _tails = tails;

  /// Splits [frames] into the part they all share and what remains of each.
  factory AnimatedSvgFrames.fromEncodedFrames(
    List<Uint8List> frames, {
    required Duration duration,
    required bool loops,
  }) {
    assert(frames.isNotEmpty);
    final int shared = _sharedPrefixLength(frames);
    return AnimatedSvgFrames._(
      shared: frames.first.sublist(0, shared),
      tails: <Uint8List>[for (final Uint8List frame in frames) frame.sublist(shared)],
      duration: duration,
      loops: loops,
    );
  }

  final Uint8List _shared;
  final List<Uint8List> _tails;

  /// How long one pass through the frames takes.
  final Duration duration;

  /// Whether playback should restart after the last frame.
  final bool loops;

  /// How many frames the animation was compiled into.
  ///
  /// Always at least one; an SVG with no animation compiles to a single frame.
  int get frameCount => _tails.length;

  /// How much memory the compiled frames occupy, in bytes.
  ///
  /// Useful for deciding whether a given SVG wants a lower frame rate.
  int get compiledByteSize =>
      _shared.length + _tails.fold(0, (int total, Uint8List tail) => total + tail.length);

  /// Whether there is anything to play.
  bool get isAnimated => frameCount > 1 && duration > Duration.zero;

  /// The encoded vector graphic for the frame at [index].
  ///
  /// Rebuilt on each call from the shared part and the frame's own, which costs
  /// a copy of a few tens of kilobytes and saves holding every frame whole.
  ByteData frameAt(int index) {
    final Uint8List tail = _tails[index];
    if (_shared.isEmpty) {
      return tail.buffer.asByteData(tail.offsetInBytes, tail.lengthInBytes);
    }
    final frame = Uint8List(_shared.length + tail.length)
      ..setRange(0, _shared.length, _shared)
      ..setRange(_shared.length, _shared.length + tail.length, tail);
    return frame.buffer.asByteData();
  }

  /// The frame to show at [progress] through the animation, from 0.0 to 1.0.
  int frameIndexAt(double progress) {
    if (frameCount <= 1) {
      return 0;
    }
    if (loops) {
      // The last frame ends just before the loop point, so the frame after it
      // is the first one again.
      final int index = (progress * frameCount).floor() % frameCount;
      return index < 0 ? index + frameCount : index;
    }
    return (progress.clamp(0.0, 1.0) * (frameCount - 1)).round();
  }
}

/// The length of the longest run of bytes every one of [frames] starts with.
///
/// The encoder lays a picture out with everything it embeds at the front, so
/// this finds the images without having to understand the binary format.
int _sharedPrefixLength(List<Uint8List> frames) {
  if (frames.length == 1) {
    return 0;
  }
  var limit = frames.first.length;
  for (final Uint8List frame in frames) {
    if (frame.length < limit) {
      limit = frame.length;
    }
  }
  for (var i = 0; i < limit; i += 1) {
    final int byte = frames.first[i];
    for (final Uint8List frame in frames) {
      if (frame[i] != byte) {
        return i;
      }
    }
  }
  return limit;
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
      final frames = <Uint8List>[
        for (var index = 0; index < frameCount; index += 1)
          vg.encodeSvg(
            xml: document.sampleAt(_frameTime(duration, index, frameCount, document.loops)),
            theme: theme,
            colorMapper: colorMapper,
            debugName: debugName,
            enableClippingOptimizer: false,
            enableMaskingOptimizer: false,
            enableOverdrawOptimizer: false,
          ),
      ];
      return AnimatedSvgFrames.fromEncodedFrames(frames, duration: duration, loops: document.loops);
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
      SynchronousFuture<ByteData>(frames.frameAt(frameIndex));

  @override
  Object cacheKey(BuildContext? context) => _AnimatedSvgFrameKey(frames, frameIndex);

  @override
  bool operator ==(Object other) =>
      other is AnimatedSvgFrameLoader &&
      identical(other.frames, frames) &&
      other.frameIndex == frameIndex;

  // Deliberately the same for every frame of one animation, even though the
  // frames are not equal to each other. The renderer namespaces its image cache
  // by the hash code of the loader it was given, so sharing one across the
  // frames lets an image embedded in the SVG be decoded once for the whole
  // animation rather than again on every frame. Different animations still get
  // different namespaces, which is what keeps their image ids apart.
  @override
  int get hashCode => identityHashCode(frames);

  @override
  String toString() => 'AnimatedSvgFrameLoader(frame $frameIndex of ${frames.frameCount})';
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
