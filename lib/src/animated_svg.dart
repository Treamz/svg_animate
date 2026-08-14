import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart' show ColorMapper, SvgTheme;
import 'package:http/http.dart' as http;
import 'package:vector_graphics/vector_graphics_compat.dart';

import 'animation/cache.dart';
import 'animation/frames.dart';
import 'color_mapper.dart';
import 'loaders.dart';

/// Builds the widget shown when an animation fails to load.
typedef SvgErrorWidgetBuilder =
    Widget Function(BuildContext context, Object error, StackTrace stackTrace);

/// Wraps the successfully loaded animation.
typedef SvgImageWidgetBuilder = Widget Function(BuildContext context, Widget child);

/// The widget shown while an animation is being compiled, when no
/// `placeholderBuilder` was given.
WidgetBuilder defaultAnimatedSvgPlaceholderBuilder = (BuildContext context) => const LimitedBox();

/// Controls the playback of an [AnimatedSvgPicture].
///
/// A controller may be created before the picture it drives has finished
/// loading. Requests made in the meantime are remembered and applied as soon as
/// the animation is ready, so there is no need to wait for loading to finish
/// before calling [play], [pause], or [seek].
///
/// Listeners are notified when playback starts or stops and when the animation
/// becomes ready. To rebuild on every frame instead, listen to [progress].
///
/// A controller may drive only one picture at a time, and must be disposed when
/// it is no longer needed.
class AnimatedSvgController extends ChangeNotifier {
  AnimationController? _playback;
  final ProxyAnimation _progress = ProxyAnimation(kAlwaysDismissedAnimation);
  bool? _playRequested;
  double? _seekRequested;
  Duration? _seekPositionRequested;
  bool _disposed = false;

  /// Whether the picture this controller drives has finished loading.
  ///
  /// Until this is true, [duration] is null and [progress] reports the position
  /// playback will start from.
  bool get isReady => _playback != null;

  /// Whether the animation is currently running.
  bool get isPlaying => _playback?.isAnimating ?? false;

  /// How long one loop of the animation takes, or null until the animation has
  /// loaded.
  Duration? get duration => _playback?.duration;

  /// How far through the animation playback is, from 0.0 to 1.0.
  ///
  /// This is a repainting [Animation], so it can be passed to widgets such as
  /// [AnimatedBuilder] to follow the animation frame by frame. The same object
  /// is returned for the life of the controller, so it may be handed out before
  /// the picture has loaded; it starts reporting once playback begins.
  Animation<double> get progress => _progress;

  /// The current position within the animation.
  Duration get position {
    final AnimationController? playback = _playback;
    if (playback == null || playback.duration == null) {
      return Duration.zero;
    }
    return playback.duration! * playback.value;
  }

  /// Starts or resumes playback.
  void play() {
    _playRequested = true;
    final AnimationController? playback = _playback;
    if (playback == null) {
      return;
    }
    if (playback.value >= 1.0 && !_repeats) {
      playback.value = 0;
    }
    if (_repeats) {
      playback.repeat();
    } else {
      playback.forward();
    }
    _notify();
  }

  /// Stops playback, leaving the animation on its current frame.
  void pause() {
    _playRequested = false;
    _playback?.stop();
    _notify();
  }

  /// Stops playback and returns to the first frame.
  void stop() {
    _playRequested = false;
    _seekRequested = 0;
    _seekPositionRequested = null;
    _playback
      ?..stop()
      ..value = 0;
    _notify();
  }

  /// Jumps to [progress] through the animation, from 0.0 to 1.0.
  ///
  /// Seeking does not start or stop playback.
  void seek(double progress) {
    final double clamped = progress.clamp(0.0, 1.0);
    _seekRequested = clamped;
    _seekPositionRequested = null;
    _playback?.value = clamped;
  }

  /// Jumps to [position] within the animation.
  void seekTo(Duration position) {
    final Duration? total = duration;
    if (total == null || total <= Duration.zero) {
      // The duration is only known once the animation has loaded, so the
      // position is held until then rather than being resolved against nothing.
      _seekPositionRequested = position;
      _seekRequested = null;
      return;
    }
    seek(position.inMicroseconds / total.inMicroseconds);
  }

  bool _repeats = false;

  void _attach(AnimationController playback, {required bool repeat, required bool autoPlay}) {
    _playback = playback;
    _progress.parent = playback;
    _repeats = repeat;
    final Duration? seekPosition = _seekPositionRequested;
    final double? seek = _seekRequested;
    if (seekPosition != null) {
      final Duration? total = playback.duration;
      playback.value = total == null || total <= Duration.zero
          ? 0
          : (seekPosition.inMicroseconds / total.inMicroseconds).clamp(0.0, 1.0);
      _seekPositionRequested = null;
      _seekRequested = playback.value;
    } else if (seek != null) {
      playback.value = seek;
    }
    if (_playRequested ?? autoPlay) {
      play();
    } else {
      _notify();
    }
  }

  void _detach() {
    _playback = null;
    _progress.parent = null;
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _playback = null;
    _progress.parent = null;
    super.dispose();
  }
}

/// A widget that renders an SVG that declares SMIL or CSS animations.
///
/// This is the animated counterpart to `SvgPicture` from `package:flutter_svg`,
/// and takes the same arguments for sizing, alignment, theming, and error
/// handling. An SVG that declares no animation renders exactly as `SvgPicture`
/// would render it.
///
/// {@tool snippet}
///
/// Playing an animated asset, looping forever:
///
/// ```dart
/// AnimatedSvgPicture.asset('assets/spinner.svg', width: 48, height: 48)
/// ```
/// {@end-tool}
///
/// ## How animation is rendered
///
/// The animations declared by the SVG are resolved when the picture loads, and
/// the document is compiled into one static vector graphic per frame. Playback
/// then swaps between those pre-compiled frames, so the per frame cost is the
/// same as drawing a static SVG. The trade off is that loading is more
/// expensive than for a still SVG, and the compiled frames occupy memory for
/// as long as they stay in [svgAnimateCache]. Use [frameRate] and
/// [maxFrames] to trade smoothness against both. Compilation happens in a
/// background isolate on platforms that have them, and on the main thread on
/// the web, where a long animation is best given a lower [frameRate].
///
/// ## Supported animation
///
/// * The SMIL elements `<animate>`, `<animateTransform>`, `<animateMotion>`,
///   and `<set>`, including `values`/`keyTimes`/`keySplines`, `from`/`to`/`by`,
///   `calcMode`, `begin`, `dur`, `end`, `repeatCount`, `repeatDur`, `fill`,
///   `additive`, and `accumulate`.
/// * CSS `@keyframes` declared in a `<style>` element, driven by the
///   `animation` shorthand or its longhand properties.
///
/// Animations that need a live document are not supported, because there is no
/// interactive document to drive them: a `begin` that waits for an event or for
/// another animation, and CSS pseudo-class selectors such as `:hover`, are
/// ignored rather than guessed at. So are CSS custom properties and the `var()`
/// values that reference them. Interpolation of the `d` attribute is also not
/// supported; such animations fall back to switching between values.
class AnimatedSvgPicture extends StatefulWidget {
  /// Renders the animated SVG that `bytesLoader` provides.
  ///
  /// Either the [width] and [height] arguments should be specified, or the
  /// widget should be placed in a context that sets tight layout constraints.
  const AnimatedSvgPicture(
    this.bytesLoader, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.matchTextDirection = false,
    this.allowDrawingOutsideViewBox = false,
    this.placeholderBuilder,
    this.colorFilter,
    this.semanticsLabel,
    this.excludeFromSemantics = false,
    this.clipBehavior = Clip.hardEdge,
    this.errorBuilder,
    this.imageBuilder,
    this.renderingStrategy = RenderingStrategy.picture,
    this.controller,
    this.autoPlay = true,
    this.repeat,
    this.onCompleted,
    this.frameRate = defaultAnimationFrameRate,
    this.maxFrames = defaultMaxAnimationFrames,
  }) : assert(frameRate > 0),
       assert(maxFrames > 0);

  /// Renders an animated SVG from an [AssetBundle].
  ///
  /// `package` must be given when the asset lives in another package, exactly
  /// as it must for `SvgPicture.asset` and [Image.asset].
  AnimatedSvgPicture.asset(
    String assetName, {
    super.key,
    AssetBundle? bundle,
    String? package,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.matchTextDirection = false,
    this.allowDrawingOutsideViewBox = false,
    this.placeholderBuilder,
    this.semanticsLabel,
    this.excludeFromSemantics = false,
    this.clipBehavior = Clip.hardEdge,
    this.errorBuilder,
    this.imageBuilder,
    SvgTheme? theme,
    ColorMapper? colorMapper,
    this.colorFilter,
    this.renderingStrategy = RenderingStrategy.picture,
    this.controller,
    this.autoPlay = true,
    this.repeat,
    this.onCompleted,
    this.frameRate = defaultAnimationFrameRate,
    this.maxFrames = defaultMaxAnimationFrames,
  }) : assert(frameRate > 0),
       assert(maxFrames > 0),
       bytesLoader = SvgAnimateAssetLoader(
         assetName,
         packageName: package,
         assetBundle: bundle,
         theme: theme,
         colorMapper: colorMapper,
       );

  /// Renders an animated SVG obtained from the network.
  ///
  /// All network SVGs are cached regardless of HTTP headers.
  AnimatedSvgPicture.network(
    String url, {
    super.key,
    Map<String, String>? headers,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.matchTextDirection = false,
    this.allowDrawingOutsideViewBox = false,
    this.placeholderBuilder,
    this.semanticsLabel,
    this.excludeFromSemantics = false,
    this.clipBehavior = Clip.hardEdge,
    this.errorBuilder,
    this.imageBuilder,
    SvgTheme? theme,
    ColorMapper? colorMapper,
    this.colorFilter,
    http.Client? httpClient,
    this.renderingStrategy = RenderingStrategy.picture,
    this.controller,
    this.autoPlay = true,
    this.repeat,
    this.onCompleted,
    this.frameRate = defaultAnimationFrameRate,
    this.maxFrames = defaultMaxAnimationFrames,
  }) : assert(frameRate > 0),
       assert(maxFrames > 0),
       bytesLoader = SvgAnimateNetworkLoader(
         url,
         headers: headers,
         theme: theme,
         colorMapper: colorMapper,
         httpClient: httpClient,
       );

  /// Renders an animated SVG obtained from a [File].
  ///
  /// On Android, this may require the
  /// `android.permission.READ_EXTERNAL_STORAGE` permission.
  AnimatedSvgPicture.file(
    File file, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.matchTextDirection = false,
    this.allowDrawingOutsideViewBox = false,
    this.placeholderBuilder,
    this.semanticsLabel,
    this.excludeFromSemantics = false,
    this.clipBehavior = Clip.hardEdge,
    this.errorBuilder,
    this.imageBuilder,
    SvgTheme? theme,
    ColorMapper? colorMapper,
    this.colorFilter,
    this.renderingStrategy = RenderingStrategy.picture,
    this.controller,
    this.autoPlay = true,
    this.repeat,
    this.onCompleted,
    this.frameRate = defaultAnimationFrameRate,
    this.maxFrames = defaultMaxAnimationFrames,
  }) : assert(frameRate > 0),
       assert(maxFrames > 0),
       bytesLoader = SvgAnimateFileLoader(file, theme: theme, colorMapper: colorMapper);

  /// Renders an animated SVG obtained from a [Uint8List] of UTF-8 encoded XML.
  AnimatedSvgPicture.memory(
    Uint8List bytes, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.matchTextDirection = false,
    this.allowDrawingOutsideViewBox = false,
    this.placeholderBuilder,
    this.semanticsLabel,
    this.excludeFromSemantics = false,
    this.clipBehavior = Clip.hardEdge,
    this.errorBuilder,
    this.imageBuilder,
    SvgTheme? theme,
    ColorMapper? colorMapper,
    this.colorFilter,
    this.renderingStrategy = RenderingStrategy.picture,
    this.controller,
    this.autoPlay = true,
    this.repeat,
    this.onCompleted,
    this.frameRate = defaultAnimationFrameRate,
    this.maxFrames = defaultMaxAnimationFrames,
  }) : assert(frameRate > 0),
       assert(maxFrames > 0),
       bytesLoader = SvgAnimateBytesLoader(bytes, theme: theme, colorMapper: colorMapper);

  /// Renders an animated SVG obtained from a [String] of XML.
  AnimatedSvgPicture.string(
    String string, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.matchTextDirection = false,
    this.allowDrawingOutsideViewBox = false,
    this.placeholderBuilder,
    this.semanticsLabel,
    this.excludeFromSemantics = false,
    this.clipBehavior = Clip.hardEdge,
    this.errorBuilder,
    this.imageBuilder,
    SvgTheme? theme,
    ColorMapper? colorMapper,
    this.colorFilter,
    this.renderingStrategy = RenderingStrategy.picture,
    this.controller,
    this.autoPlay = true,
    this.repeat,
    this.onCompleted,
    this.frameRate = defaultAnimationFrameRate,
    this.maxFrames = defaultMaxAnimationFrames,
  }) : assert(frameRate > 0),
       assert(maxFrames > 0),
       bytesLoader = SvgAnimateStringLoader(string, theme: theme, colorMapper: colorMapper);

  /// The loader that provides the SVG markup to animate.
  ///
  /// This is an [SvgSourceLoader] rather than a `BytesLoader`, because the
  /// animation is resolved from the markup itself rather than from an already
  /// compiled vector graphic.
  final SvgSourceLoader<Object?> bytesLoader;

  /// If specified, the width to use for the SVG.
  final double? width;

  /// If specified, the height to use for the SVG.
  final double? height;

  /// How to inscribe the picture into the space allocated during layout.
  final BoxFit fit;

  /// How to align the picture within its parent widget.
  final AlignmentGeometry alignment;

  /// The placeholder to use while the animation is being compiled.
  ///
  /// Compiling an animation takes longer than decoding a static SVG, so
  /// providing a placeholder matters more here than it does for a still image.
  final WidgetBuilder? placeholderBuilder;

  /// If true, will horizontally flip the picture in [TextDirection.rtl]
  /// contexts.
  final bool matchTextDirection;

  /// If true, will allow the SVG to be drawn outside of the clip boundary of
  /// its viewBox.
  final bool allowDrawingOutsideViewBox;

  /// The [Semantics.label] for this picture.
  final String? semanticsLabel;

  /// Whether to exclude this picture from semantics.
  final bool excludeFromSemantics;

  /// The content will be clipped (or not) according to this option.
  final Clip clipBehavior;

  /// Widget displayed while the animation failed to load.
  final SvgErrorWidgetBuilder? errorBuilder;

  /// A builder that wraps the successfully loaded animation.
  final SvgImageWidgetBuilder? imageBuilder;

  /// The color filter, if any, to apply to this widget.
  final ColorFilter? colorFilter;

  /// Widget rendering strategy used to balance flexibility and performance.
  ///
  /// Defaults to [RenderingStrategy.picture]. [RenderingStrategy.raster] is a
  /// poor fit for animation, because every frame would be rasterized anew.
  final RenderingStrategy renderingStrategy;

  /// An optional controller for driving playback from outside this widget.
  ///
  /// When null, the animation plays according to [autoPlay] and [repeat] and
  /// cannot be controlled.
  final AnimatedSvgController? controller;

  /// Whether the animation starts playing as soon as it has loaded.
  final bool autoPlay;

  /// Whether the animation restarts when it reaches the end.
  ///
  /// Defaults to null, meaning the SVG decides: markup that asks to repeat
  /// forever, such as `repeatCount="indefinite"` or a CSS `infinite` iteration
  /// count, loops, and markup whose animations all end plays once and holds its
  /// final frame. Set this to true or false to override that.
  final bool? repeat;

  /// Called each time playback reaches the end of the animation.
  ///
  /// Called once for a non-repeating animation, and after every loop when
  /// [repeat] is true.
  final VoidCallback? onCompleted;

  /// How many frames to compile per second of animation.
  ///
  /// Lower values compile faster and use less memory at the cost of smoothness.
  /// The effective rate may be lower than this if the animation is long enough
  /// to hit [maxFrames].
  final double frameRate;

  /// The most frames this animation may be compiled into.
  ///
  /// Animations long enough to exceed this are compiled at a lower frame rate
  /// rather than taking an unbounded amount of memory.
  final int maxFrames;

  @override
  State<AnimatedSvgPicture> createState() => _AnimatedSvgPictureState();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);

    properties
      ..add(StringProperty('bytesLoader', bytesLoader.toString(), showName: false))
      ..add(DoubleProperty('width', width, defaultValue: null))
      ..add(DoubleProperty('height', height, defaultValue: null))
      ..add(DoubleProperty('frameRate', frameRate, defaultValue: defaultAnimationFrameRate))
      ..add(IntProperty('maxFrames', maxFrames, defaultValue: defaultMaxAnimationFrames))
      ..add(DiagnosticsProperty<bool>('autoPlay', autoPlay, defaultValue: true))
      ..add(DiagnosticsProperty<bool>('repeat', repeat, defaultValue: null))
      ..add(
        DiagnosticsProperty<AlignmentGeometry>(
          'alignment',
          alignment,
          defaultValue: Alignment.center,
        ),
      )
      ..add(EnumProperty<BoxFit>('fit', fit, defaultValue: BoxFit.contain))
      ..add(StringProperty('colorFilter', colorFilter.toString(), defaultValue: null))
      ..add(StringProperty('semanticsLabel', semanticsLabel, defaultValue: null));
  }
}

/// The cache key for a compiled animation.
///
/// The frame rate and frame ceiling are part of the key because they change the
/// frames that get compiled, not just how they are played back.
@immutable
class _AnimationCacheKey {
  const _AnimationCacheKey(this.loaderKey, this.frameRate, this.maxFrames);

  final Object loaderKey;
  final double frameRate;
  final int maxFrames;

  @override
  bool operator ==(Object other) =>
      other is _AnimationCacheKey &&
      other.loaderKey == loaderKey &&
      other.frameRate == frameRate &&
      other.maxFrames == maxFrames;

  @override
  int get hashCode => Object.hash(loaderKey, frameRate, maxFrames);
}

// Uses [TickerProviderStateMixin] rather than the single ticker variant because
// a new playback controller, and so a new ticker, is created every time the
// animation is recompiled.
class _AnimatedSvgPictureState extends State<AnimatedSvgPicture> with TickerProviderStateMixin {
  AnimationController? _playback;
  AnimatedSvgFrames? _frames;
  Object? _error;
  StackTrace? _stackTrace;
  int _frameIndex = 0;
  int _loadGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(AnimatedSvgPicture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach();
      final AnimationController? playback = _playback;
      if (playback != null && _frames != null) {
        widget.controller?._attach(playback, repeat: _repeats(_frames!), autoPlay: widget.autoPlay);
      }
    }
    final AnimatedSvgFrames? frames = _frames;
    if (oldWidget.repeat != widget.repeat && frames != null) {
      final bool repeats = _repeats(frames);
      widget.controller?._repeats = repeats;
      final AnimationController? playback = _playback;
      if (playback != null && playback.isAnimating) {
        if (repeats) {
          playback.repeat();
        } else {
          playback.forward();
        }
      }
    }
    if (oldWidget.bytesLoader != widget.bytesLoader ||
        oldWidget.frameRate != widget.frameRate ||
        oldWidget.maxFrames != widget.maxFrames) {
      _load();
    }
  }

  @override
  void dispose() {
    widget.controller?._detach();
    _disposePlayback();
    super.dispose();
  }

  void _disposePlayback() {
    final AnimationController? playback = _playback;
    _playback = null;
    playback
      ?..removeListener(_handleTick)
      ..removeStatusListener(_handleStatus)
      ..dispose();
  }

  Object _cacheKey() =>
      _AnimationCacheKey(widget.bytesLoader.cacheKey(context), widget.frameRate, widget.maxFrames);

  Future<void> _load() async {
    final SvgSourceLoader<Object?> loader = widget.bytesLoader;
    final Object key = _cacheKey();
    _loadGeneration += 1;
    final int generation = _loadGeneration;
    try {
      // Deliberately chained rather than awaited: loaders may complete
      // synchronously, and an `await` on a synchronous future would let a
      // parse failure escape the future chain rather than reporting it here.
      final AnimatedSvgFrames frames = await svgAnimateCache.putIfAbsent(
        key,
        () => loader
            .loadSvgSource(context)
            .then(
              (SvgSource source) => compileAnimatedSvgFrames(
                source.xml,
                theme: source.theme.toVgTheme(),
                colorMapper: toVgColorMapper(source.colorMapper),
                frameRate: widget.frameRate,
                maxFrames: widget.maxFrames,
                debugName: loader.toString(),
              ),
            ),
      );
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      if (identical(frames, _frames) && _error == null) {
        // The reload resolved to the animation that is already playing, so it
        // keeps playing rather than jumping back to its first frame.
        return;
      }
      setState(() {
        _error = null;
        _stackTrace = null;
        _frames = frames;
        _frameIndex = 0;
      });
      _startPlayback(frames);
    } catch (error, stackTrace) {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _error = error;
        _stackTrace = stackTrace;
        _frames = null;
      });
    }
  }

  bool _repeats(AnimatedSvgFrames frames) => widget.repeat ?? frames.loops;

  void _startPlayback(AnimatedSvgFrames frames) {
    _disposePlayback();
    if (!frames.isAnimated) {
      widget.controller?._detach();
      return;
    }
    final playback = AnimationController(vsync: this, duration: frames.duration)
      ..addListener(_handleTick)
      ..addStatusListener(_handleStatus);
    _playback = playback;
    final AnimatedSvgController? controller = widget.controller;
    if (controller != null) {
      controller._attach(playback, repeat: _repeats(frames), autoPlay: widget.autoPlay);
    } else if (widget.autoPlay) {
      if (_repeats(frames)) {
        playback.repeat();
      } else {
        playback.forward();
      }
    }
  }

  void _handleTick() {
    final AnimatedSvgFrames? frames = _frames;
    final AnimationController? playback = _playback;
    if (frames == null || playback == null) {
      return;
    }
    final int index = frames.frameIndexAt(playback.value);
    if (index == _frameIndex) {
      return;
    }
    // A looping animation never reports `completed`, so a frame index that goes
    // backwards is what marks the end of a loop.
    final bool wrapped = index < _frameIndex;
    setState(() {
      _frameIndex = index;
    });
    if (wrapped) {
      widget.onCompleted?.call();
    }
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onCompleted?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final Object? error = _error;
    if (error != null) {
      return widget.errorBuilder?.call(context, error, _stackTrace ?? StackTrace.empty) ??
          _placeholder(context);
    }
    final AnimatedSvgFrames? frames = _frames;
    if (frames == null) {
      return _placeholder(context);
    }
    return createCompatVectorGraphic(
      loader: AnimatedSvgFrameLoader(frames, _frameIndex),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      semanticsLabel: widget.semanticsLabel,
      excludeFromSemantics: widget.excludeFromSemantics,
      clipBehavior: widget.clipBehavior,
      errorBuilder: widget.errorBuilder,
      imageBuilder: widget.imageBuilder,
      colorFilter: widget.colorFilter,
      placeholderBuilder: widget.placeholderBuilder,
      strategy: widget.renderingStrategy,
      clipViewbox: !widget.allowDrawingOutsideViewBox,
      matchTextDirection: widget.matchTextDirection,
    );
  }

  Widget _placeholder(BuildContext context) =>
      (widget.placeholderBuilder ?? defaultAnimatedSvgPlaceholderBuilder)(context);
}
