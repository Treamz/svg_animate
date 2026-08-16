import 'package:flutter/foundation.dart';

import 'frames.dart';

/// The cache for compiled animated SVGs.
///
/// Compiling an animation produces one encoded vector graphic per frame, which
/// is far more expensive to build and to hold than a single static picture, so
/// this cache holds fewer entries by default than the cache for static SVGs.
///
/// Entries are bounded by [maximumSizeBytes] as well as by [maximumSize],
/// because how much an animation costs to hold and how many animations there
/// are turn out to have very little to do with each other: a spinner compiles
/// to a few kilobytes and a promotional banner carrying embedded bitmaps to
/// several megabytes, so a count that is generous for one is ruinous for the
/// other.
class AnimationCache {
  final Map<Object, Future<AnimatedSvgFrames>> _pending = <Object, Future<AnimatedSvgFrames>>{};
  final Map<Object, AnimatedSvgFrames> _cache = <Object, AnimatedSvgFrames>{};

  // Recorded when the entry goes in rather than asked of the entry when it
  // comes out, so that what is subtracted is always exactly what was added, and
  // so that measuring an animation stays proportional to its frame count
  // instead of happening on every eviction.
  final Map<Object, int> _sizes = <Object, int>{};

  /// Maximum number of animations to store in the cache.
  ///
  /// Once this many entries have been cached, the least-recently-used entry is
  /// evicted when adding a new entry.
  int get maximumSize => _maximumSize;
  int _maximumSize = 10;

  /// Changes the maximum cache size.
  ///
  /// If the new size is smaller than the current number of elements, the
  /// extraneous elements are evicted immediately. Setting this to zero and then
  /// returning it to its original value will therefore immediately clear the
  /// cache.
  set maximumSize(int value) {
    assert(value >= 0);
    if (value == _maximumSize) {
      return;
    }
    _maximumSize = value;
    if (_maximumSize == 0) {
      clear();
    } else {
      _evictToBudget();
    }
  }

  /// Maximum number of bytes of compiled animation to hold.
  ///
  /// Defaults to 20 MiB, which is room for a handful of the heaviest sort of
  /// animation — a large SVG with bitmaps embedded in it — and for as many
  /// ordinary ones as [maximumSize] allows. It sits well below the 100 MiB that
  /// Flutter's own `ImageCache` takes by default.
  ///
  /// The one thing this does not do is refuse an animation bigger than the
  /// whole budget. Refusing it would quietly disable the cache for exactly the
  /// files that most need one, turning every rebuild back into a recompile
  /// measured in seconds, so such an animation is kept — alone, with everything
  /// else evicted to make room for it.
  ///
  /// Setting this to zero disables caching, as setting [maximumSize] to zero
  /// does.
  int get maximumSizeBytes => _maximumSizeBytes;
  int _maximumSizeBytes = _defaultMaximumSizeBytes;
  static const int _defaultMaximumSizeBytes = 20 << 20;

  /// Changes the maximum number of bytes to hold.
  ///
  /// Anything held over the new budget is evicted immediately, least recently
  /// used first.
  set maximumSizeBytes(int value) {
    assert(value >= 0);
    if (value == _maximumSizeBytes) {
      return;
    }
    _maximumSizeBytes = value;
    if (_maximumSizeBytes == 0) {
      clear();
    } else {
      _evictToBudget();
    }
  }

  /// How many bytes of compiled animation are currently held.
  int get currentSizeBytes => _currentSizeBytes;
  int _currentSizeBytes = 0;

  /// Evicts all entries from the cache.
  void clear() {
    _cache.clear();
    _sizes.clear();
    _currentSizeBytes = 0;
  }

  /// The animation cached under [key], if it is there.
  ///
  /// Unlike [putIfAbsent] this compiles nothing, so a caller can tell whether
  /// the expensive work has already been done before deciding to do anything
  /// about the wait.
  AnimatedSvgFrames? operator [](Object key) {
    final AnimatedSvgFrames? cached = _cache[key];
    if (cached != null) {
      _touch(key); // Reading counts as use.
    }
    return cached;
  }

  /// Evicts a single entry from the cache, returning true if successful.
  bool evict(Object key) {
    return _remove(key);
  }

  /// The number of entries in the cache.
  int get count => _cache.length;

  /// Returns the previously compiled animation for [key], if available, and
  /// otherwise calls [loader] to compile it.
  ///
  /// In either case the key is moved to the "most recently used" position.
  Future<AnimatedSvgFrames> putIfAbsent(Object key, Future<AnimatedSvgFrames> Function() loader) {
    final Future<AnimatedSvgFrames>? pendingResult = _pending[key];
    if (pendingResult != null) {
      return pendingResult;
    }

    final AnimatedSvgFrames? cached = _cache[key];
    if (cached != null) {
      _touch(key);
      return SynchronousFuture<AnimatedSvgFrames>(cached);
    }

    // `Future.sync` is used rather than calling `loader` directly because
    // parsing can fail synchronously: a `SynchronousFuture` earlier in the
    // chain runs its continuation inline, which lets an error escape before
    // this method has had a chance to attach a handler to it.
    final result = Future<AnimatedSvgFrames>.sync(loader);
    _pending[key] = result;
    return result.then(
      (AnimatedSvgFrames frames) {
        _pending.remove(key);
        _add(key, frames);
        return frames;
      },
      onError: (Object error, StackTrace stackTrace) {
        _pending.remove(key);
        throw Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }

  void _add(Object key, AnimatedSvgFrames frames) {
    if (_maximumSize <= 0 || _maximumSizeBytes <= 0) {
      return;
    }
    _remove(key);
    _cache[key] = frames;
    final int size = frames.compiledByteSize;
    _sizes[key] = size;
    _currentSizeBytes += size;
    _evictToBudget();
  }

  bool _remove(Object key) {
    if (_cache.remove(key) == null) {
      return false;
    }
    _currentSizeBytes -= _sizes.remove(key)!;
    return true;
  }

  /// Moves [key] to the "most recently used" position without disturbing the
  /// accounting, which cannot have changed: an [AnimatedSvgFrames] never does.
  void _touch(Object key) {
    final AnimatedSvgFrames? frames = _cache.remove(key);
    if (frames != null) {
      _cache[key] = frames;
    }
  }

  void _evictToBudget() {
    // Dart maps iterate in insertion order, so the first key is the one used
    // longest ago. The length check is what keeps a single over-budget
    // animation from evicting itself the instant it is added.
    while (_cache.length > _maximumSize ||
        (_currentSizeBytes > _maximumSizeBytes && _cache.length > 1)) {
      _remove(_cache.keys.first);
    }
  }
}

/// The cache of compiled animations shared by every [AnimatedSvgPicture].
///
/// Entries are large, because an animation holds one compiled vector graphic
/// per frame, so this holds far fewer of them than the picture caches in
/// `package:flutter_svg` do. Lower [AnimationCache.maximumSizeBytes] to trade
/// recompilation for memory, or set it to zero to disable caching entirely.
final AnimationCache svgAnimateCache = AnimationCache();
