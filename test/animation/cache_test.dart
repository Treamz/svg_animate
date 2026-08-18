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
}
