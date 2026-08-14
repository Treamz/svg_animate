import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/src/animation/frames.dart';

/// A frame that begins with [shared] and ends with [tail].
Uint8List frame(List<int> shared, List<int> tail) => Uint8List.fromList(<int>[...shared, ...tail]);

void main() {
  group('AnimatedSvgFrames', () {
    test('rebuilds every frame exactly as it was compiled', () {
      final List<Uint8List> compiled = <Uint8List>[
        frame(<int>[1, 2, 3, 4], <int>[9]),
        frame(<int>[1, 2, 3, 4], <int>[8, 8]),
        frame(<int>[1, 2, 3, 4], <int>[7, 7, 7]),
      ];
      final AnimatedSvgFrames frames = AnimatedSvgFrames.fromEncodedFrames(
        compiled,
        duration: const Duration(seconds: 1),
        loops: true,
      );

      expect(frames.frameCount, 3);
      for (var i = 0; i < compiled.length; i += 1) {
        expect(frames.frameAt(i).buffer.asUint8List(), compiled[i], reason: 'frame $i');
      }
    });

    test('stores what the frames share only once', () {
      final List<Uint8List> compiled = <Uint8List>[
        frame(List<int>.filled(1000, 7), <int>[1]),
        frame(List<int>.filled(1000, 7), <int>[2]),
        frame(List<int>.filled(1000, 7), <int>[3]),
      ];
      final AnimatedSvgFrames frames = AnimatedSvgFrames.fromEncodedFrames(
        compiled,
        duration: const Duration(seconds: 1),
        loops: true,
      );

      // 1000 shared bytes plus one byte per frame, rather than 3003.
      expect(frames.compiledByteSize, 1003);
    });

    test('costs nothing when the frames share nothing', () {
      final List<Uint8List> compiled = <Uint8List>[
        Uint8List.fromList(<int>[1, 1, 1]),
        Uint8List.fromList(<int>[2, 2, 2]),
      ];
      final AnimatedSvgFrames frames = AnimatedSvgFrames.fromEncodedFrames(
        compiled,
        duration: const Duration(seconds: 1),
        loops: true,
      );

      expect(frames.compiledByteSize, 6);
      expect(frames.frameAt(0).buffer.asUint8List(), compiled[0]);
      expect(frames.frameAt(1).buffer.asUint8List(), compiled[1]);
    });

    test('handles a single frame, which shares nothing with anything', () {
      final AnimatedSvgFrames frames = AnimatedSvgFrames.fromEncodedFrames(
        <Uint8List>[
          Uint8List.fromList(<int>[4, 5, 6]),
        ],
        duration: Duration.zero,
        loops: false,
      );

      expect(frames.frameCount, 1);
      expect(frames.isAnimated, isFalse);
      expect(frames.frameAt(0).buffer.asUint8List(), <int>[4, 5, 6]);
    });

    test('picks the frame to show from the progress', () {
      final AnimatedSvgFrames looping = AnimatedSvgFrames.fromEncodedFrames(
        <Uint8List>[
          for (var i = 0; i < 4; i += 1) Uint8List.fromList(<int>[i]),
        ],
        duration: const Duration(seconds: 1),
        loops: true,
      );
      expect(looping.frameIndexAt(0), 0);
      expect(looping.frameIndexAt(0.5), 2);
      // The end of a loop is the start of the next one.
      expect(looping.frameIndexAt(1), 0);

      final AnimatedSvgFrames once = AnimatedSvgFrames.fromEncodedFrames(
        <Uint8List>[
          for (var i = 0; i < 4; i += 1) Uint8List.fromList(<int>[i]),
        ],
        duration: const Duration(seconds: 1),
        loops: false,
      );
      // A one-shot animation ends on its last frame rather than wrapping.
      expect(once.frameIndexAt(1), 3);
    });
  });
}
