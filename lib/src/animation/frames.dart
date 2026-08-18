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
    required List<int>? storage,
    required this.duration,
    required this.loops,
  }) : _shared = shared,
       _tails = tails,
       _storage = storage;

  /// Splits [frames] into the part they all share and what remains of each,
  /// keeping only one copy of any frame that repeats.
  factory AnimatedSvgFrames.fromEncodedFrames(
    List<Uint8List> frames, {
    required Duration duration,
    required bool loops,
  }) {
    assert(frames.isNotEmpty);
    final int shared = _sharedPrefixLength(frames);
    final tails = <Uint8List>[for (final Uint8List frame in frames) frame.sublist(shared)];
    final _DistinctTails distinct = _distinctTails(tails);
    return AnimatedSvgFrames._(
      shared: frames.first.sublist(0, shared),
      tails: distinct.tails,
      storage: distinct.storage,
      duration: duration,
      loops: loops,
    );
  }

  final Uint8List _shared;

  /// The distinct frames, in the order they are first sampled.
  final List<Uint8List> _tails;

  /// Which of [_tails] each sampled frame shows, or null when they all differ.
  final List<int>? _storage;

  /// How long one pass through the frames takes.
  final Duration duration;

  /// Whether playback should restart after the last frame.
  final bool loops;

  /// How many frames the animation was sampled at.
  ///
  /// This is the resolution of the timeline rather than the number of pictures
  /// held: frames that came out of the compiler identical are stored once, so
  /// this can be larger than [distinctFrameCount]. Always at least one; an SVG
  /// with no animation compiles to a single frame.
  int get frameCount => _storage?.length ?? _tails.length;

  /// How many of the sampled frames actually differ from one another.
  ///
  /// A document that declares an animation the renderer cannot express — a
  /// morphing `d`, say — samples to any number of frames that are all the same
  /// picture, and reports one here.
  int get distinctFrameCount => _tails.length;

  /// How much memory the compiled frames occupy, in bytes.
  ///
  /// Useful for deciding whether a given SVG wants a lower frame rate.
  int get compiledByteSize =>
      _shared.length + _tails.fold(0, (int total, Uint8List tail) => total + tail.length);

  /// Whether there is anything to play.
  ///
  /// Counts pictures rather than sampling points, so an animation that never
  /// changes what it draws is not played: there is nothing for a ticker to do
  /// but repaint the same picture until the widget goes away.
  bool get isAnimated => distinctFrameCount > 1 && duration > Duration.zero;

  /// The encoded vector graphic for the frame at [index].
  ///
  /// Rebuilt on each call from the shared part and the frame's own, which costs
  /// a copy of a few tens of kilobytes and saves holding every frame whole.
  ByteData frameAt(int index) {
    final Uint8List tail = _tails[_storageIndexAt(index)];
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

  /// Which stored picture the frame at [index] shows.
  ///
  /// Two frames that resolve to the same picture are the same picture, which is
  /// what lets playback skip decoding one it is already showing.
  int _storageIndexAt(int index) => _storage?[index] ?? index;
}

/// The distinct entries of a list of frame tails, and where each frame found
/// its own.
class _DistinctTails {
  const _DistinctTails(this.tails, this.storage);

  final List<Uint8List> tails;

  /// Null when nothing repeated, so that the common case carries no table.
  final List<int>? storage;
}

/// Keeps one copy of each distinct entry of [tails].
///
/// Frames repeat whenever the document holds still: a `<set>`, a discrete
/// `calcMode`, a CSS `steps()` timing function, or simply a long gap between
/// keyframes all sample to the same picture many times over. So does an
/// animation of something the renderer cannot draw, which samples to nothing
/// but copies of one frame.
_DistinctTails _distinctTails(List<Uint8List> tails) {
  if (tails.length == 1) {
    return _DistinctTails(tails, null);
  }
  // Digests first, because comparing every frame against every distinct one it
  // is not equal to would cost the square of the frame count in byte
  // comparisons. A collision costs one comparison that fails; equality is never
  // concluded from the digest alone.
  final buckets = <int, List<int>>{};
  final distinct = <Uint8List>[];
  final storage = List<int>.filled(tails.length, 0);
  for (var index = 0; index < tails.length; index += 1) {
    final Uint8List tail = tails[index];
    final List<int> bucket = buckets.putIfAbsent(_digest(tail), () => <int>[]);
    var found = -1;
    for (final int candidate in bucket) {
      if (_sameBytes(distinct[candidate], tail)) {
        found = candidate;
        break;
      }
    }
    if (found < 0) {
      found = distinct.length;
      distinct.add(tail);
      bucket.add(found);
    }
    storage[index] = found;
  }
  if (distinct.length == tails.length) {
    return _DistinctTails(tails, null);
  }
  return _DistinctTails(distinct, storage);
}

/// An FNV-1a digest of [bytes], masked to stay a small integer everywhere.
int _digest(Uint8List bytes) {
  var hash = 0x811c9dc5;
  for (var i = 0; i < bytes.length; i += 1) {
    hash = ((hash ^ bytes[i]) * 0x01000193) & 0x3fffffff;
  }
  return hash ^ bytes.length;
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i += 1) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
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

  // Both of these speak in stored pictures rather than in frame numbers, so
  // that a run of frames the compiler produced identically is recognised as the
  // one picture it is: the widget then neither reloads it nor caches it twice
  // while the animation sits on it.
  @override
  Object cacheKey(BuildContext? context) =>
      _AnimatedSvgFrameKey(frames, frames._storageIndexAt(frameIndex));

  @override
  bool operator ==(Object other) =>
      other is AnimatedSvgFrameLoader &&
      identical(other.frames, frames) &&
      frames._storageIndexAt(other.frameIndex) == frames._storageIndexAt(frameIndex);

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

  /// An index into the stored pictures, not into the frames.
  final int frameIndex;

  @override
  bool operator ==(Object other) =>
      other is _AnimatedSvgFrameKey &&
      identical(other.frames, frames) &&
      other.frameIndex == frameIndex;

  @override
  int get hashCode => Object.hash(identityHashCode(frames), frameIndex);
}
