import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svg_animate/svg_animate.dart';

class _Bytes extends BytesLoader {
  const _Bytes(this.data);
  final ByteData data;
  @override
  Future<ByteData> loadBytes(BuildContext? context) async => data;
}

/// The red channel at each of [points] of [svg]'s first frame, drawn at
/// 100 x 100 over white.
Future<List<int>> redAt(String svg, List<(int, int)> points) async {
  final AnimatedSvgFrames frames = await compileAnimatedSvg(svg);
  final PictureInfo info = await vg.loadPicture(_Bytes(frames.frameAt(0)), null);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.src);
  canvas.scale(100 / info.size.width, 100 / info.size.height);
  canvas.drawPicture(info.picture);
  final ui.Image image = await recorder.endRecording().toImage(100, 100);
  final ByteData pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return <int>[for (final (int x, int y) in points) pixels.getUint8((y * 100 + x) * 4)];
}

/// A black square under a mask with a translucent part, an opaque part, a hole,
/// and a translucent part over an opaque one.
String masked(String maskAttributes) =>
    '''
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">
  <defs><mask id="m" $maskAttributes>
    <rect x="10" y="10" width="40" height="80" fill="#fff" fill-opacity="0.3"/>
    <rect x="50" y="10" width="40" height="80" fill="#fff"/>
    <circle cx="70" cy="50" r="10" fill="#000"/>
    <rect x="60" y="80" width="20" height="10" fill="#fff" opacity="0.5"/>
  </mask></defs>
  <rect width="100" height="100" fill="#000" mask="url(#m)">
    <animate attributeName="x" values="0;0" dur="1s"/>
  </rect>
</svg>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  svgAnimateReportDiagnostics = false;

  test('a translucent part of a mask lets that much through', () async {
    // White at 30% covers 30%: black drawn through it over white is 70% white.
    // The renderer read the colour without its alpha and covered fully.
    final List<int> red = await redAt(masked(''), <(int, int)>[(30, 50)]);

    expect(red.single, closeTo(179, 2));
  });

  test('the rest of the mask reads as before', () async {
    final List<int> red = await redAt(masked(''), <(int, int)>[
      (55, 30), // opaque white: fully covered
      (70, 50), // black hole: nothing
      (5, 5), // outside every shape: nothing
      (70, 85), // translucent white over opaque white: still white
    ]);

    expect(red, <int>[0, 255, 255, 0]);
  });
}
