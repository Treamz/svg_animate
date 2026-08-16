import 'package:flutter/foundation.dart';

import 'frames.dart';

/// The cache for compiled animated SVGs.
///
/// Compiling an animation produces one encoded vector graphic per frame, which
/// is far more expensive to build and to hold than a single static picture, so
/// this cache holds fewer entries by default than the cache for static SVGs.
class AnimationCache {
  final Map<Object, Future<AnimatedSvgFrames>> _pending = <Object, Future<AnimatedSvgFrames>>{};
  final Map<Object, AnimatedSvgFrames> _cache = <Object, AnimatedSvgFrames>{};

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
      while (_cache.length > _maximumSize) {
        _cache.remove(_cache.keys.first);
      }
    }
  }

  /// Evicts all entries from the cache.
  void clear() {
    _cache.clear();
  }

  /// The animation cached under [key], if it is there.
  ///
  /// Unlike [putIfAbsent] this compiles nothing, so a caller can tell whether
  /// the expensive work has already been done before deciding to do anything
  /// about the wait.
  AnimatedSvgFrames? operator [](Object key) {
    final AnimatedSvgFrames? cached = _cache.remove(key);
    if (cached != null) {
      _add(key, cached); // Reading counts as use.
    }
    return cached;
  }

  /// Evicts a single entry from the cache, returning true if successful.
  bool evict(Object key) {
    return _cache.remove(key) != null;
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

    final AnimatedSvgFrames? cached = _cache.remove(key);
    if (cached != null) {
      _add(key, cached);
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
    if (_maximumSize <= 0) {
      return;
    }
    if (_cache.containsKey(key)) {
      _cache.remove(key); // Update the LRU position.
    } else if (_cache.length >= _maximumSize) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = frames;
  }
}

/// The cache of compiled animations shared by every [AnimatedSvgPicture].
///
/// Entries are large, because an animation holds one compiled vector graphic
/// per frame, so this holds far fewer of them than the picture caches in
/// `package:flutter_svg` do. Lower [AnimationCache.maximumSize] to trade
/// recompilation for memory, or set it to zero to disable caching entirely.
final AnimationCache svgAnimateCache = AnimationCache();
