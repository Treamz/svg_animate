import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/src/animation/document.dart';
import 'package:svg_animate/svg_animate.dart';

class _Bytes extends BytesLoader {
  const _Bytes(this.data);
  final ByteData data;
  @override
  Future<ByteData> loadBytes(BuildContext? context) async => data;
}

/// The red channel in the middle of a 20 unit thick horizontal stroke, drawn
/// over white, in the frame of [body] at [milliseconds].
Future<int> strokeAt(String body, {int milliseconds = 0}) async {
  final AnimatedSvgFrames frames = await compileAnimatedSvg(
    '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">'
    '$body</svg>',
    frameRate: 10,
  );
  final int index = frames.frameCount == 1
      ? 0
      : (milliseconds / frames.duration.inMilliseconds * (frames.frameCount - 1)).round();
  final PictureInfo info = await vg.loadPicture(_Bytes(frames.frameAt(index)), null);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.src);
  canvas.drawPicture(info.picture);
  final ui.Image image = await recorder.endRecording().toImage(100, 100);
  final ByteData pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return pixels.getUint8((50 * 100 + 50) * 4);
}

/// Something animated elsewhere, so the document compiles as an animation.
const String ticking =
    '<rect width="1" height="1" fill="none"><animate attributeName="x" values="0;1" dur="1s" fill="freeze"/></rect>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  svgAnimateReportDiagnostics = false;

  test('a path hidden with opacity under a stroked group stays hidden', () async {
    // The compiler drew the group's stroke at full strength whatever the
    // path's own opacity said.
    final int red = await strokeAt(
      '<g stroke="#000" stroke-width="20" fill="none"><path d="M0 50H100" opacity="0"/></g>$ticking',
    );

    expect(red, 255);
  });

  test('a translucent path under a stroked group is translucent', () async {
    final int red = await strokeAt(
      '<g stroke="#000" stroke-width="20" fill="none"><path d="M0 50H100" opacity="0.5"/></g>$ticking',
    );

    expect(red, closeTo(128, 2));
  });

  test("the group's stroke opacity still combines with the path's opacity", () async {
    final int red = await strokeAt(
      '<g stroke="#000" stroke-opacity="0.5" stroke-width="20" fill="none">'
      '<path d="M0 50H100" opacity="0.5"/></g>$ticking',
    );

    expect(red, closeTo(191, 2));
  });

  test('a path shown by a set appears when the set begins', () async {
    const String body =
        '<g stroke="#000" stroke-width="20" fill="none"><path d="M0 50H100" opacity="0">'
        '<set attributeName="opacity" to="1" begin="0.5s" fill="freeze"/></path></g>$ticking';

    expect(await strokeAt(body), 255);
    expect(await strokeAt(body, milliseconds: 1000), 0);
  });

  test('the stroke written onto a path is gone again before the next frame', () {
    // Only frames where the path has an opacity of its own need the stroke.
    final AnimatedSvgDocument document = AnimatedSvgDocument.parse(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
      '<g stroke="#000"><path d="M0 50H100">'
      '<set attributeName="opacity" to="0" begin="0.5s" dur="0.2s"/></path></g></svg>',
    );

    expect(
      document.sampleAt(const Duration(milliseconds: 600)),
      contains('opacity="0" stroke="#000"'),
    );
    expect(document.sampleAt(Duration.zero), contains('<path d="M0 50H100"/>'));
  });
}
