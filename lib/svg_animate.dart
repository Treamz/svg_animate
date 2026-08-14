/// Plays SVGs that declare their own animation, in SMIL or CSS keyframes.
///
/// The animations a document declares are resolved when the picture loads, and
/// the document is compiled into one static vector graphic per frame by the
/// same `vector_graphics` pipeline that `package:flutter_svg` uses. Playback
/// then swaps between those frames, so drawing one costs the same as drawing a
/// still SVG.
///
/// See [AnimatedSvgPicture] for the widget, and [AnimatedSvgController] for
/// driving playback.
library;

export 'src/animated_svg.dart';
export 'src/animation/cache.dart' show AnimationCache, svgAnimateCache;
export 'src/animation/frames.dart'
    show AnimatedSvgFrames, defaultAnimationFrameRate, defaultMaxAnimationFrames;
export 'src/color_mapper.dart' show toVgColorMapper;
export 'src/loaders.dart';
