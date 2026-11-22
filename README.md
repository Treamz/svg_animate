# svg_animate

[![pub package](https://img.shields.io/pub/v/svg_animate.svg)](https://pub.dev/packages/svg_animate)
[![pub points](https://img.shields.io/pub/points/svg_animate)](https://pub.dev/packages/svg_animate/score)
[![license](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.38-blue)](https://flutter.dev)
[![platform](https://img.shields.io/badge/platform-android%20%7C%20ios%20%7C%20macos%20%7C%20windows%20%7C%20linux%20%7C%20web-lightgrey)](https://pub.dev/packages/svg_animate)

**[Live demo](https://treamz.github.io/svg_animate/)** — the example app, built
for the web and running the package rather than describing it. Its **Try your
own** tab takes an SVG of yours, as a file, a URL or pasted markup, and reports
what compiling it produced: how many frames, how many of those actually differ,
what they cost, and anything in the file that will not survive being drawn.

Plays SVGs that declare their own animation — SMIL (`<animate>`,
`<animateTransform>`, `<animateMotion>`, `<set>`), CSS `@keyframes`, and CSS
motion paths — using the same `vector_graphics` renderer that
[`flutter_svg`](https://pub.dev/packages/flutter_svg) draws still SVGs with.

<!-- markdownlint-disable MD033 -->
<img src="https://raw.githubusercontent.com/Treamz/svg_animate/main/doc/demo.svg"
     width="440" alt="Four animated SVGs: a rotating spinner, a pulsing ring, a progress bar, and a marker following a path">
<!-- markdownlint-enable MD033 -->

*The image above is a single SVG file, animating in your browser exactly as it
does in Flutter through this package. Its source is
[`doc/demo.svg`](doc/demo.svg).*

`AnimatedSvgPicture` is a drop-in companion to `SvgPicture`: it takes the same
arguments for sizing, alignment, theming, color filtering, semantics and error
handling, and reuses `flutter_svg`'s `SvgTheme`, `ColorMapper` and
`DefaultSvgTheme`. An SVG with no animation renders exactly as `SvgPicture`
renders it, and starts no ticker.

```dart
AnimatedSvgPicture.asset('assets/spinner.svg', width: 48, height: 48)
```

Files exported by animation editors work as they come. SVGator, the most common
of them, expresses every movement as a CSS motion path and places repeated
artwork through `<use>`; both are handled, including exports that embed their
artwork as raster images. See [what is not supported](#what-is-not-supported)
for the parts of such files that do not survive.

## Getting started

```yaml
dependencies:
  svg_animate: ^0.6.0
```

There are constructors for every source `flutter_svg` supports:

```dart
AnimatedSvgPicture.asset('assets/spinner.svg');
AnimatedSvgPicture.network('https://example.com/spinner.svg');
AnimatedSvgPicture.file(File(path));
AnimatedSvgPicture.memory(bytes);
AnimatedSvgPicture.string(markup);
```

## Playback

By default the animation starts as soon as it loads, and **the SVG decides
whether it repeats**: markup that asks to loop forever does, and markup whose
animations all end plays once and holds its final frame. Pass `repeat` to
override that.

```dart
AnimatedSvgPicture.asset(
  'assets/progress.svg',
  repeat: false,
  onCompleted: () => debugPrint('done'),
);
```

For play/pause/seek, pass an `AnimatedSvgController`. It can be used before the
picture has loaded — requests are remembered and applied once it is ready.

```dart
final controller = AnimatedSvgController();

AnimatedSvgPicture.asset(
  'assets/spinner.svg',
  controller: controller,
  autoPlay: false,
);

controller.play();
controller.pause();
controller.seek(0.5);                                  // 0.0 to 1.0
controller.seekTo(const Duration(milliseconds: 500));

controller.speed = 2.0;                                // 1.0 is the file's own
controller.reverse();                                  // back towards frame one
```

`speed` and `reverse` cost nothing: the frames are compiled once and are not
compiled again, so only how long playback takes to walk through them changes.
An animation that repeats keeps repeating backwards; one that does not stops at
its first frame, and `onCompleted` is called there as it is at the end of a pass
the other way. A speed far above 1 walks through the same frames in less time
and so shows fewer of them per second — `frameRate` decides how many there are,
and that is settled when the animation is compiled.

`controller.progress` is a stable `Animation<double>`, so it can be handed to an
`AnimatedBuilder` to follow playback frame by frame, even before loading
finishes.

### Less motion

Somebody who finds movement uncomfortable turns Reduce Motion on in their system
settings. An `AnimatedSvgPicture` loads as usual, draws its first frame, and
starts no ticker.

```dart
AnimatedSvgPicture.asset(
  'assets/spinner.svg',
  respectReduceMotion: false, // it says the app is still working
);
```

Turn it off for an animation that carries information rather than decorating: a
still spinner reads as a frozen app. Reduce Motion is about movement nobody
asked for, not about everything that moves.

Only starting on its own is given up. A controller told to `play` plays either
way — that is the app asking on purpose, and the app is the thing that knows
whether its animation means something.

### In a widget test

A looping animation never settles, so `pumpAndSettle` times out on a screen
carrying one, and says nothing about which widget kept it awake. Ask for less
motion and the picture holds its first frame:

```dart
await tester.pumpWidget(
  MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: yourScreen,
  ),
);
await tester.pumpAndSettle();
```

To test the animation itself rather than the screen around it, drive it instead:
pass an `AnimatedSvgController`, `autoPlay: false`, and `seek` to the frame you
want.

## Supported SVG features

### Animation

| | |
|---|---|
| `<animate>` | `values` / `keyTimes` / `keySplines`, `from` / `to` / `by` |
| `<animateTransform>` | `translate`, `scale`, `rotate`, `skewX`, `skewY` |
| `<animateMotion>` | `path` and `<mpath>`, `rotate="auto"` / `auto-reverse` |
| `<set>` | yes |
| `calcMode` | `linear`, `discrete`, `paced`, `spline` |
| Timing | `begin` (offsets, lists of them, and the `begin` or `end` of another animation plus an offset), `dur`, `end`, `repeatCount`, `repeatDur`, `fill`, `restart` |
| Composition | `additive="sum"`, `accumulate="sum"` |
| Targeting | `href` / `xlink:href`, or the parent element |
| CSS `@keyframes` | `animation` shorthand and every longhand, per-keyframe `animation-timing-function` |
| `animation-direction` | `normal`, `reverse`, `alternate`, `alternate-reverse` |
| `animation-fill-mode` | `forwards` and `both` hold the last frame |
| CSS motion paths | `offset-path: path(...)`, `offset-distance`, `offset-rotate` |
| `transform-origin` | resolved against the view box |
| Animated value types | numbers, lengths, percentages, colors (hex, `rgb()`, `hsl()`, SVG keywords), number lists, transform lists, path data (`d`) |
| Path morphing | `d` blends between paths with the same commands, absolute or relative, as SVG 2 defines; paths whose commands differ switch halfway |

Animations that start one another — `begin="dot3.end+0.25s"`, which is how
most loaders in [svg-spinners](https://github.com/n3r4zzurr0/svg-spinners) are
built — are resolved when the SVG is compiled, `restart` included. A chain that
restarts itself plays as a loop of the period it makes. That loop is the
chain's settled pattern: where a run carries over into the next period, as the
waves of a pulse do, the warm-up in the very first period, before the later
waves have started, is not reproduced.

### Drawing

Everything is drawn by `vector_graphics`, so an animated SVG supports exactly
what a still one does through `flutter_svg`: paths and shapes, linear and radial
gradients, patterns, `clipPath`, `mask`, text, embedded raster images, and the
fifteen CSS blend modes.

Four things that a still SVG does *not* get are handled here, because the
renderer cannot do them on its own:

- **CSS in a `<style>` element** is resolved into presentation attributes. The
  `vector_graphics` compiler implements no CSS selectors, so without this a
  stylesheet-driven SVG renders unstyled. `SvgPicture` ignores `<style>`
  entirely.
- **A `<use>` pointing at an `<image>`** is expanded into the image. The
  renderer loses an image's size through a reference and then fails the whole
  picture rather than that one element.
- **`stroke-dashoffset` and `pathLength`** are laid out here. The compiler
  reads neither, so the usual way of drawing a path on, a dash as long as the
  path slid along it by animating the offset, compiled to a picture that never
  moved. The dashes are cut with the compiler's own dasher, starting again at
  each subpath as browsers do, and written into each frame as plain path data.
  A dash array on its own goes the same way, which puts dots along a curve
  where browsers put them.
- **A shape's own `opacity` over a stroke it inherits** is kept. The compiler
  applies a shape's `opacity` to its stroke only when the shape names its own
  stroke colour, so a path that takes its stroke from a group and is hidden
  with `opacity="0"` drew in full. The inherited stroke is written onto the
  shape, which the compiler then fades.

### What is not supported

| | why |
|---|---|
| `<filter>` beyond blur, offset and merge | `vector_graphics_compiler` 1.3.6 and later, which need Flutter 3.41, draw `feGaussianBlur`, `feOffset` and `feMerge` — so a soft shadow or a plain glow is drawn, and its `stdDeviation`, `dx` and `dy` animate — and leave out the whole of a filter that uses any other primitive, such as the `feFlood` and `feColorMatrix` in the drop shadows design tools export. On an earlier Flutter no filter is drawn; where the whole filter is one `feGaussianBlur`, the diagnostic below gives the `imageBuilder` that approximates it. Either way the element still draws, without the effect |
| `mix-blend-mode: plus-lighter` | not among the fifteen modes the renderer knows; editors reach for it to make a glow |
| `clip-path` over `<text>` | the clip does not reach the letters, which draw in full whatever it says. Clipping shapes works; this is the one thing it does not reach. Reported as `unclippedText` |
| `begin` on an event, `indefinite`, or another animation's repeat | there is no interactive document to fire it. A list that also holds a time, or the begin or end of another animation, keeps those |
| CSS pseudo-classes such as `:hover` | same |
| CSS custom properties and `var()` | left alone, so the element keeps the presentation attribute it already had |
| `<script>` | not run |
| `@media`, `@supports` | skipped rather than guessed at |

### When nothing moves

An SVG that will not animate looks exactly like one that has not started yet: a
still picture and no error at all. Every compiled animation carries a list of
what it asked for that will not happen, and in debug builds an
`AnimatedSvgPicture` prints it the first time the SVG is compiled.

```dart
final AnimatedSvgFrames frames = await compileAnimatedSvg(markup);
for (final SvgAnimateDiagnostic diagnostic in frames.diagnostics) {
  debugPrint('${diagnostic.kind}: ${diagnostic.message}');
}
```

| kind | what it means |
|---|---|
| `noAnimation` | nothing to play. If the file also has a `<script>`, it was exported for an editor's own JavaScript player and the markup holds only the first frame; re-export it as CSS or SMIL animation |
| `neverChanges` | an animation was declared, and every frame of it drew the same picture. The message names the attributes it animates |
| `unreachableImage` | an `<image>` points somewhere other than a `data:` URI; the compiler fetches nothing, so the image is left out of every frame |
| `droppedFilter` | a `<filter>` is used that the renderer leaves out. Which filters those are depends on the version of `vector_graphics` the app resolves, so the compiler in use is asked rather than a list consulted: a filter it draws is not reported. The message names the primitives it does not draw. On a Flutter older than 3.41 it also says what upgrading would draw, and if the whole of a filter is one `feGaussianBlur`, it carries the `ImageFiltered` that comes closest, with the file's own `stdDeviation` in it — that blurs the whole picture rather than the one element, and its sigma is in the SVG's units, so it wants scaling with the picture |
| `reducedFrameRate` | the animation is longer than `maxFrames` allows at `frameRate`, so it was sampled over its whole length at a lower rate |
| `unclippedText` | a `clip-path` applies over `<text>`, which it will not reach; the letters draw in full from the first frame to the last |
| `expensive` | the compiled animation came to more than 4 MB. The message says how large, over how many frames, how many of those are different pictures, and which of `frameRate` and `maxFrames` changes it |

Set `svgAnimateReportDiagnostics` to `false` to keep the printing out of a test
that loads such a file deliberately.

### Guarding your own SVGs

An SVG that has stopped animating looks exactly like one that has not started,
so it survives a code review, a glance at the app, and a release. The same check
this package runs over its own example assets is a dozen lines to copy:

```dart
test('assets/spinner.svg animates', () async {
  final AnimatedSvgFrames frames =
      await compileAnimatedSvg(File('assets/spinner.svg').readAsStringSync());

  expect(frames.diagnostics, isEmpty);
  expect(frames.isAnimated, isTrue);
  expect(frames.distinctFrameCount, greaterThan(1));
});
```

`distinctFrameCount` is the one to keep: frames that all draw the same picture
are a still SVG with a ticker, and the count is how you tell.

What this does not catch is a document whose values change and whose drawing
does not — a `clip-path` over `<text>` is the example, since the clip changes on
every frame and the letters are drawn in full regardless. The frames differ, so
a check like the one above is satisfied. Only pixels catch that, which is what
golden tests are for.

## How it compares

This package deliberately covers less of SVG than the alternatives, and carries
much less with it.

- It renders through `vector_graphics`, the same renderer `flutter_svg` uses, so
  animated and still SVGs in one app are drawn by the same code and share
  `SvgTheme` and `ColorMapper`.
- It adds two pure Dart packages, `xml` and `path_parsing`, both already in
  `flutter_svg`'s own dependency tree. No JavaScript runtime, no native engine,
  no FFI.
- A frame costs what a still SVG costs to draw, because frames are compiled
  ahead of time rather than evaluated as they are shown.

Which to reach for:

| | |
|---|---|
| **svg_animate** | Spinners, loaders, animated icons, exports from animation editors. You already use `flutter_svg` and want to keep the dependency list short. |
| [**full_svg_flutter**](https://pub.dev/packages/full_svg_flutter) | You need filters beyond blur, offset and merge, `d` morphing, or SVGs that carry `<script>`. It covers considerably more of the format, and bundles a QuickJS runtime and `woff2` to do it. |
| [**anim_svg**](https://pub.dev/packages/anim_svg) | You would rather transpile to Lottie and render through the native thorvg engine. |
| [**flutter_svg**](https://pub.dev/packages/flutter_svg) | The SVG does not animate. |
| [**lottie**](https://pub.dev/packages/lottie), [**rive**](https://pub.dev/packages/rive) | The animation is authored in those formats to begin with. Both are far more capable than any SVG animation runtime, if you can choose the format. |

What is written above about other packages comes from their descriptions and
dependency lists, not from benchmarking them.

For a longer walk-through, including `animated_svg` and `drawing_animation`,
see
[how svg_animate plays animated SVGs in Flutter, and how it compares with Lottie and other packages](https://treamz.me/blog/flutter-svg-animation).

## How it works, and what it costs

When the picture loads, the animations the document declares are resolved, and
the document is sampled to a static SVG at each frame time. Each sample is
compiled by `vector_graphics_compiler` — the same compiler `flutter_svg` uses —
in a background isolate. Playback then swaps between those pre-compiled frames,
so drawing one costs the same as drawing a still SVG.

The trade-off is loading: compiling *N* frames takes roughly *N* times as long
as loading a still SVG, and the frames stay in memory while they are cached.

The awkward case is an SVG that embeds raster images, because the image data
appears in every compiled frame and is far larger than the drawing around it.
Two things keep that affordable. The run of bytes every frame begins with, which
is where the encoder puts whatever a picture embeds, is stored once instead of
per frame. And an embedded image is decoded once for the whole animation instead
of on every frame change. For a 450×450 banner carrying five embedded bitmaps
that is 5.1 MB rather than 27.5 MB, and 1.5 ms rather than 6.8 ms to change
frame — the same cost as an SVG that embeds nothing at all.

Frames that come out of the compiler identical are also stored once. A document
holds still more often than it looks: a `<set>`, a discrete `calcMode`, a CSS
`steps()` timing function or a long gap between keyframes all sample to the same
picture repeatedly, so a one-second blink at the default frame rate holds two
pictures rather than sixty. An animation that never changes what it draws is not
played at all, since a ticker would have nothing to do but repaint it.

An animation can say what it costs rather than being guessed at:

```dart
final AnimatedSvgFrames frames = await compileAnimatedSvg(markup);
debugPrint('${frames.frameCount} frames, ${frames.distinctFrameCount} distinct, '
    '${frames.compiledByteSize} bytes');
```

- `frameRate` (default `60`) — frames compiled per second of animation.
- `maxFrames` (default `300`) — ceiling; longer animations are sampled at a
  lower rate rather than growing without bound.
- `placeholderBuilder` — shown until there is a picture. The first frame is
  compiled ahead of the rest, so it appears well before the animation is ready
  to move.
- `svgAnimateCache` — the shared cache of compiled animations. It is bounded by
  `maximumSizeBytes` (default 20 MiB) as well as by `maximumSize` (default 10
  entries), because a spinner and a banner carrying embedded bitmaps differ in
  size by three orders of magnitude and a count alone says very little about
  memory. `currentSizeBytes` reports what is held.

On the web there are no isolates, so compilation runs on the main thread; prefer
a lower `frameRate` for long animations there.

Editing an SVG and hot reloading shows the edit. An animation is cached under
what identifies its source rather than under its contents, so a reload throws
away what was compiled from the version before it and compiles the file again.
Debug builds only.

Compiling is what the wait is made of, and it can be done before anything is
waiting. `precacheAnimatedSvg` compiles an animation into the same cache the
picture reads, so the picture is there the moment the widget is:

```dart
@override
void didChangeDependencies() {
  super.didChangeDependencies();
  precacheAnimatedSvg(const SvgAnimateAssetLoader('assets/intro.svg'), context);
}
```

Pass the context the picture will be built under, since that is what resolves an
enclosing `DefaultSvgTheme` and `DefaultAssetBundle`, and pass the same
`frameRate` and `maxFrames`: an animation compiled at one frame rate is not the
one compiled at another, and they are cached apart. It returns the compiled
frames, so it can also answer what an animation costs before deciding anything
about it.

## Contributing

Development setup and the release process are in
[CONTRIBUTING.md](CONTRIBUTING.md). Releases are cut by pushing a `v0.0.0` tag;
GitHub Actions verifies the tagged commit and publishes it.

## License

BSD 3-Clause. Portions are derived from the Flutter project, which is
distributed under the same license.
