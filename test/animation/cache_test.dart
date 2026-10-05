import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/src/animation/cache.dart';
import 'package:svg_animate/src/animation/frames.dart';

/// An animation of one frame occupying [bytes] bytes.
AnimatedSvgFrames sized(int bytes) => AnimatedSvgFrames.fromEncodedFrames(
  <Uint8List>[Uint8List(bytes)],
  duration: const Duration(seconds: 1),
  loops: true,
);

Future<AnimatedSvgFrames> put(AnimationCache cache, Object key, int bytes) {
  final AnimatedSvgFrames frames = sized(bytes);
  return cache.putIfAbsent(key, () async => frames);
}

void main() {
  group('AnimationCache byte budget', () {
    test('reports what it is holding', () async {
      final AnimationCache cache = AnimationCache();
      await put(cache, 'a', 100);
      await put(cache, 'b', 250);

      expect(cache.count, 2);
      expect(cache.currentSizeBytes, 350);
    });

    test('evicts the least recently used until it is within budget', () async {
      final AnimationCache cache = AnimationCache()..maximumSizeBytes = 1000;
      await put(cache, 'a', 400);
      await put(cache, 'b', 400);
      await put(cache, 'c', 400);

      // 'a' is the one nothing has touched since it went in.
      expect(cache['a'], isNull);
      expect(cache['b'], isNotNull);
      expect(cache['c'], isNotNull);
      expect(cache.currentSizeBytes, 800);
    });

    test('counts reading as use, so a read entry outlives an unread one', () async {
      final AnimationCache cache = AnimationCache()..maximumSizeBytes = 1000;
      await put(cache, 'a', 400);
      await put(cache, 'b', 400);
      cache['a'];
      await put(cache, 'c', 400);

      expect(cache['a'], isNotNull, reason: 'read after being added, so used more recently');
      expect(cache['b'], isNull);
    });

    test('keeps an animation larger than the whole budget, alone', () async {
      final AnimationCache cache = AnimationCache()..maximumSizeBytes = 1000;
      await put(cache, 'small', 100);
      await put(cache, 'huge', 5000);

      // Refusing it would turn every rebuild of the heaviest sort of file back
      // into a recompile, which is the one thing the cache exists to prevent.
      expect(cache['huge'], isNotNull);
      expect(cache['small'], isNull);
      expect(cache.currentSizeBytes, 5000);

      // And it does not wedge the cache: the next animation displaces it.
      await put(cache, 'next', 100);
      expect(cache['huge'], isNull);
      expect(cache.currentSizeBytes, 100);
    });

    test('still honours the entry count', () async {
      final AnimationCache cache = AnimationCache()
        ..maximumSizeBytes = 1 << 30
        ..maximumSize = 2;
      await put(cache, 'a', 1);
      await put(cache, 'b', 1);
      await put(cache, 'c', 1);

      expect(cache.count, 2);
      expect(cache['a'], isNull);
      expect(cache.currentSizeBytes, 2);
    });

    test('evicts down to a lowered budget immediately', () async {
      final AnimationCache cache = AnimationCache();
      await put(cache, 'a', 400);
      await put(cache, 'b', 400);

      cache.maximumSizeBytes = 500;

      expect(cache.count, 1);
      expect(cache['b'], isNotNull);
      expect(cache.currentSizeBytes, 400);
    });

    test('a budget of zero caches nothing', () async {
      final AnimationCache cache = AnimationCache()..maximumSizeBytes = 0;
      await put(cache, 'a', 100);

      expect(cache.count, 0);
      expect(cache.currentSizeBytes, 0);
    });

    test('keeps the accounting straight through eviction and clearing', () async {
      final AnimationCache cache = AnimationCache();
      await put(cache, 'a', 100);
      await put(cache, 'b', 200);

      expect(cache.evict('a'), isTrue);
      expect(cache.currentSizeBytes, 200);
      expect(cache.evict('a'), isFalse, reason: 'evicting twice must not double-count');
      expect(cache.currentSizeBytes, 200);

      cache.clear();
      expect(cache.currentSizeBytes, 0);

      // Re-adding after a clear starts the count again rather than resuming it.
      await put(cache, 'a', 100);
      expect(cache.currentSizeBytes, 100);
    });

    test('replacing an entry does not count it twice', () async {
      final AnimationCache cache = AnimationCache();
      await put(cache, 'a', 100);
      cache.evict('a');
      await put(cache, 'a', 700);

      expect(cache.count, 1);
      expect(cache.currentSizeBytes, 700);
    });
  });

  group('a compile that is still running', () {
    /// Starts a compile and holds it open, so that a cache operation can happen
    /// in the middle of one. That window is the only place these behaviours
    /// exist, and it is the window a hot reload lands in.
    (Future<AnimatedSvgFrames>, Completer<void>) held(
      AnimationCache cache,
      Object key,
      AnimatedSvgFrames result,
    ) {
      final gate = Completer<void>();
      return (
        cache.putIfAbsent(key, () async {
          await gate.future;
          return result;
        }),
        gate,
      );
    }

    test('is disowned by evict, so the next ask compiles again', () async {
      // Without this a hot reload evicts, reloads, and is handed back the
      // animation compiled from the file as it was before the edit.
      final cache = AnimationCache();
      final AnimatedSvgFrames before = sized(16);
      final AnimatedSvgFrames after = sized(32);

      final (Future<AnimatedSvgFrames> running, Completer<void> gate) = held(cache, 'k', before);
      expect(cache.evict('k'), isTrue, reason: 'there was something to evict');

      gate.complete();
      await running;
      expect(cache.count, 0, reason: 'the disowned compile was not stored');

      final AnimatedSvgFrames next = await cache.putIfAbsent('k', () async => after);
      expect(identical(next, after), isTrue, reason: 'and the next ask compiled again');
    });

    test('is disowned by clear, so memory given back stays given back', () async {
      final cache = AnimationCache();
      final (Future<AnimatedSvgFrames> running, Completer<void> gate) = held(cache, 'k', sized(64));

      cache.clear();
      gate.complete();
      await running;

      expect(cache.count, 0);
      expect(cache.currentSizeBytes, 0);
    });

    test('still gives its result to whoever was already waiting', () async {
      // Disowning decides what the cache keeps. It does not fail the caller who
      // asked before it happened.
      final cache = AnimationCache();
      final AnimatedSvgFrames frames = sized(16);
      final (Future<AnimatedSvgFrames> running, Completer<void> gate) = held(cache, 'k', frames);

      cache.clear();
      gate.complete();

      expect(identical(await running, frames), isTrue);
    });

    test('and does not evict the compile that replaced it', () async {
      // The reason the pending entry is checked by identity rather than just
      // removed: a disowned compile finishing later must not take the live one
      // with it.
      final cache = AnimationCache();
      final AnimatedSvgFrames first = sized(16);
      final AnimatedSvgFrames second = sized(32);

      final (Future<AnimatedSvgFrames> running, Completer<void> gate) = held(cache, 'k', first);
      cache.evict('k');
      final (Future<AnimatedSvgFrames> replacement, Completer<void> other) = held(
        cache,
        'k',
        second,
      );

      gate.complete();
      await running;
      other.complete();

      expect(identical(await replacement, second), isTrue);
      expect(cache.count, 1, reason: 'the replacement was kept');
      expect(cache.currentSizeBytes, 32);
    });
  });
}
