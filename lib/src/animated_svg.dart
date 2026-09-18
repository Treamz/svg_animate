import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart' show ColorMapper, SvgTheme;
import 'package:http/http.dart' as http;
import 'package:vector_graphics/vector_graphics_compat.dart';

import 'animation/cache.dart';
import 'animation/diagnostics.dart';
import 'animation/frames.dart';
import 'color_mapper.dart';
import 'loaders.dart';
import 'utilities/file.dart';

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
  bool _reversed = false;

  /// How long one pass takes at a speed of 1, which is what [speed] scales.
  ///
  /// Held separately because the playback controller's own duration is the
  /// scaled one, so reading the speed back out of it would compound.
  Duration _naturalDuration = Duration.zero;

  /// Whether the picture this controller drives has finished loading.
  ///
  /// Until this is true, [duration] is null and [progress] reports the position
  /// playback will start from.
  bool get isReady => _playback != null;

  /// Whether the animation is currently running.
  bool get isPlaying => _playback?.isAnimating ?? false;

  /// How long one pass through the animation takes at the current [speed], or
  /// null until the animation has loaded.
  ///
  /// This is what [position] and [seekTo] are measured against, so raising the
  /// speed shortens it rather than leaving it reporting the timing the file
  /// declared.
  Duration? get duration => _playback?.duration;

  /// How fast playback runs, as a multiple of the timing the SVG declares.
  ///
  /// 1.0, the default, is the file's own timing; 2.0 is twice as fast and 0.5
  /// half. Must be greater than zero — to run backwards use [reverse], since a
  /// negative speed would mean two things at once and neither clearly.
  ///
  /// Changing this costs nothing. The frames were compiled once and are not
  /// recompiled: only how long playback takes to walk through them changes, so
  /// the animation is not evicted from the cache and nothing is parsed again.
  /// The frame rate an animation was compiled at is unaffected, which means a
  /// speed far above 1 walks through the same frames in less time and so shows
  /// fewer of them per second.
  double get speed => _speed;
  double _speed = 1.0;

  /// Changes the playback speed, taking effect immediately.
  set speed(double value) {
    assert(value > 0, 'speed must be greater than zero; use reverse() to play backwards');
    if (value == _speed) {
      return;
    }
    _speed = value;
    final AnimationController? playback = _playback;
    if (playback == null) {
      return;
    }
    _applySpeed(playback);
    if (playback.isAnimating) {
      // A controller reads its duration when it is told to run, so a change
      // made while it is already running only lands if it is told again.
      _drive(playback);
    }
    _notify();
  }

  /// Whether playback is running, or was last asked to run, backwards.
  bool get isReversed => _reversed;

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

  /// Starts or resumes playback, running forwards.
  void play() {
    _reversed = false;
    _start();
  }

  /// Starts or resumes playback, running backwards towards the first frame.
  ///
  /// Called at the first frame of an animation that has finished, this starts
  /// again from the last one, the way [play] starts again from the first.
  ///
  /// An animation that repeats keeps repeating backwards. One that does not
  /// stops at its first frame, and `onCompleted` is called there, as it is at
  /// the end of a pass the other way.
  void reverse() {
    _reversed = true;
    _start();
  }

  void _start() {
    _playRequested = true;
    final AnimationController? playback = _playback;
    if (playback == null) {
      return;
    }
    if (_reversed) {
      if (playback.value <= 0.0) {
        playback.value = 1.0;
      }
    } else if (playback.value >= 1.0 && !_repeats) {
      playback.value = 0;
    }
    _drive(playback);
    _notify();
  }

  void _drive(AnimationController playback) {
    if (_reversed) {
      // `repeat` only ever runs forwards, so a backwards loop is started again
      // by hand from [_handleLoopStatus] each time it reaches the start.
      playback.reverse();
    } else if (_repeats) {
      playback.repeat();
    } else {
      playback.forward();
    }
  }

  void _applySpeed(AnimationController playback) {
    playback.duration = _speed == 1.0 ? _naturalDuration : _naturalDuration * (1 / _speed);
  }

  /// Whether a pass that is running backwards is under way.
  ///
  /// Read by the picture to tell reaching the first frame at the end of such a
  /// pass, which is the end of it, from reaching it because playback was
  /// stopped or seeked there, which is not.
  bool get _isRunningBackwards => _reversed && (_playRequested ?? false);

  /// Stops playback, leaving the animation on its current frame.
  void pause() {
    _playRequested = false;
    _playback?.stop();
    _notify();
  }

  /// Stops playback and returns to the first frame.
  ///
  /// Playback is left pointing forwards, so a [play] after this runs the way it
  /// would have before any [reverse].
  void stop() {
    _playRequested = false;
    _reversed = false;
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
    _naturalDuration = playback.duration ?? Duration.zero;
    // Before the held seek is resolved below, because that resolves a position
    // against the duration and the duration is the one the speed decides.
    _applySpeed(playback);
    playback.addStatusListener(_handleLoopStatus);
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
      // `_start` rather than `play`, which would turn a `reverse` asked for
      // before the picture loaded back into a forward pass.
      _start();
    } else {
      _notify();
    }
  }

  void _detach() {
    _playback?.removeStatusListener(_handleLoopStatus);
    _playback = null;
    _progress.parent = null;
  }

  /// Starts the next backwards pass of a looping animation.
  ///
  /// [AnimationController.repeat] runs forwards whatever it is given, so the
  /// loop is closed here: reaching the start while running backwards jumps back
  /// to the end and runs again.
  void _handleLoopStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _repeats && _isRunningBackwards) {
      _playback?.reverse(from: 1.0);
      return;
    }
    if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
      // Playback stopping because it ran out is a change in [isPlaying] that
      // nothing else reports, so a play button driven by this controller would
      // otherwise go on showing a pause icon until something else rebuilt it.
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // The picture owns the playback controller and may outlive this one, so the
    // listener has to come off or it goes on firing into a disposed notifier.
    _playback?.removeStatusListener(_handleLoopStatus);
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
      AnimatedSvgCacheKey(widget.bytesLoader.cacheKey(context), widget.frameRate, widget.maxFrames);

  Future<void> _load() async {
    final SvgSourceLoader<Object?> loader = widget.bytesLoader;
    final Object key = _cacheKey();
    _loadGeneration += 1;
    final int generation = _loadGeneration;
    try {
      final AnimatedSvgFrames? cached = svgAnimateCache[key];
      if (cached != null) {
        _adopt(cached, generation);
        return;
      }

      // Deliberately chained rather than awaited: loaders may complete
      // synchronously, and an `await` on a synchronous future would let a
      // parse failure escape the future chain rather than reporting it here.
      final SvgSource source = await loader.loadSvgSource(context);
      if (!mounted || generation != _loadGeneration) {
        return;
      }

      // Compiling every frame of a long animation takes long enough to be worth
      // waiting through a placeholder for, and the first frame alone takes a
      // fraction of it. So it is compiled on its own and shown while the rest
      // are still being worked out: the picture appears, then it starts moving.
      final AnimatedSvgFrames poster = await _posterFor(key, source, loader);
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      if (_frames == null) {
        _adopt(poster, generation);
      }

      final AnimatedSvgFrames frames = await svgAnimateCache.putIfAbsent(
        key,
        () => _compile(source, loader, frameCap: widget.maxFrames),
      );
      _reportDiagnostics(frames, loader);
      _adopt(frames, generation);
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

  /// The compilations of a first frame that are in flight, so that several
  /// pictures waiting on the same animation ask for it once between them.
  ///
  /// Short lived by nature: an entry lives only until the full animation
  /// arrives, which is what everything waiting is really after.
  static final Map<Object, Future<AnimatedSvgFrames>> _pendingPosters =
      <Object, Future<AnimatedSvgFrames>>{};

  Future<AnimatedSvgFrames> _posterFor(
    Object key,
    SvgSource source,
    SvgSourceLoader<Object?> loader,
  ) {
    final Future<AnimatedSvgFrames>? pending = _pendingPosters[key];
    if (pending != null) {
      return pending;
    }
    final Future<AnimatedSvgFrames> poster = _compile(source, loader, frameCap: 1);
    _pendingPosters[key] = poster;
    return poster.whenComplete(() => _pendingPosters.remove(key));
  }

  Future<AnimatedSvgFrames> _compile(
    SvgSource source,
    SvgSourceLoader<Object?> loader, {
    required int frameCap,
  }) {
    return compileAnimatedSvgFrames(
      source.xml,
      theme: source.theme.toVgTheme(),
      colorMapper: toVgColorMapper(source.colorMapper),
      frameRate: widget.frameRate,
      maxFrames: frameCap,
      debugName: loader.toString(),
    );
  }

  /// Shows [frames], and starts them playing if there is anything to play.
  void _adopt(AnimatedSvgFrames frames, int generation) {
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
  }

  // An animation that will not play looks exactly like one that has not
  // started yet, and neither raises anything. Saying so once, where a developer
  // is already looking, is the difference between a puzzle and a sentence.
  // Debug builds only, and only the first time an animation is compiled, since
  // the cache serves every picture after that.
  void _reportDiagnostics(AnimatedSvgFrames frames, SvgSourceLoader<Object?> loader) {
    if (!svgAnimateReportDiagnostics || frames.diagnostics.isEmpty) {
      return;
    }
    assert(() {
      for (final SvgAnimateDiagnostic diagnostic in frames.diagnostics) {
        debugPrint('svg_animate: $loader\n  ${diagnostic.message}');
      }
      return true;
    }());
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
    // backwards is what marks the end of a loop. Going forwards only, though.
    // A backwards pass ends at `dismissed`, which [_handleStatus] has, and the
    // index would be no use for it in any case: a looping animation shows its
    // first frame at both ends of the range, so running backwards it appears to
    // jump on the way out of the last frame as well as on the way into it.
    //
    // The direction is asked of the controller rather than of the playback
    // controller's status, which has already turned to `dismissed` by the tick
    // that carries the last value of a backwards pass — so reading it here
    // would count that tick as a wrap and report the end of the pass twice.
    final bool backwards = widget.controller?._isRunningBackwards ?? false;
    final bool wrapped = index < _frameIndex && !backwards;
    setState(() {
      _frameIndex = index;
    });
    if (wrapped) {
      widget.onCompleted?.call();
    }
  }

  void _handleStatus(AnimationStatus status) {
    final bool backwards = widget.controller?._isRunningBackwards ?? false;
    if (status == AnimationStatus.completed) {
      // Running backwards, arriving at the last frame is where a pass begins
      // rather than where one ended: either because [AnimatedSvgController
      // .reverse] was called at the first frame, or because a backwards loop
      // has just been started again from the end.
      if (!backwards) {
        widget.onCompleted?.call();
      }
      return;
    }
    // The first frame is where a backwards pass ends — every one of them,
    // looping or not, since a backwards loop is started again from there. It is
    // also where stopping and seeking to the start land, and arriving is
    // reported the same way in all three cases, so asking the controller
    // whether a backwards pass is under way is what tells them apart.
    if (status == AnimationStatus.dismissed && backwards) {
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
