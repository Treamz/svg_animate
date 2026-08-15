import 'package:flutter_svg/flutter_svg.dart' show ColorMapper, SvgTheme;

import 'animation/frames.dart';
import 'color_mapper.dart';

/// Compiles the animation in [source] into the frames it will be played back
/// from, without showing it.
///
/// [AnimatedSvgPicture] does this for itself, so reach for it only to find out
/// what an animation costs before deciding how to configure it:
///
/// ```dart
/// final AnimatedSvgFrames frames = await compileAnimatedSvg(markup);
/// debugPrint('${frames.frameCount} frames, ${frames.compiledByteSize} bytes');
/// ```
///
/// SVGs that embed raster images are the ones worth measuring; everything else
/// compiles to far less than a megabyte. The work happens in a background
/// isolate on platforms that have them.
Future<AnimatedSvgFrames> compileAnimatedSvg(
  String source, {
  SvgTheme theme = const SvgTheme(),
  ColorMapper? colorMapper,
  double frameRate = defaultAnimationFrameRate,
  int maxFrames = defaultMaxAnimationFrames,
}) {
  return compileAnimatedSvgFrames(
    source,
    theme: theme.toVgTheme(),
    colorMapper: toVgColorMapper(colorMapper),
    frameRate: frameRate,
    maxFrames: maxFrames,
  );
}
