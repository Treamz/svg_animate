# svg_animate

[![pub package](https://img.shields.io/pub/v/svg_animate.svg)](https://pub.dev/packages/svg_animate)

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
  svg_animate: ^0.3.0
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
```

`controller.progress` is a stable `Animation<double>`, so it can be handed to an
`AnimatedBuilder` to follow playback frame by frame, even before loading
finishes.

## What is supported

- **SMIL**: `<animate>`, `<animateTransform>`, `<animateMotion>` (with `path`
  and `<mpath>`), and `<set>`, including `values` / `keyTimes` / `keySplines`,
  `from` / `to` / `by`, `calcMode` (`linear`, `discrete`, `paced`, `spline`),
  `begin`, `dur`, `end`, `repeatCount`, `repeatDur`, `fill`, `additive`,
  `accumulate`, and `href` targeting.
- **CSS**: `@keyframes` in a `<style>` element, driven by the `animation`
  shorthand or its longhand properties, with `transform-origin` resolved against
  the view box.
- **CSS motion paths**: `offset-path: path(...)` with an animated
  `offset-distance` and `offset-rotate`, which is how SVGator and similar
  editors express movement.
- Interpolation of numbers, lengths, percentages, colors (hex, `rgb()`, `hsl()`,
  and the SVG keywords), number lists, and transform lists.

This package also works around two things the renderer underneath cannot do on
its own. It resolves the CSS in a `<style>` element into presentation
attributes, which is what makes stylesheet-driven SVGs render at all, since the
`vector_graphics` compiler does not implement CSS selectors. And it expands a
`<use>` that points at an `<image>` into the image itself, because the renderer
loses the image's size through a reference and then fails the whole picture
rather than that one element.

### What is not supported

Anything that needs a live, interactive document is ignored rather than guessed
at: a `begin` that waits for an event or on another animation, and CSS
pseudo-class selectors such as `:hover`. CSS custom properties and the `var()`
values that reference them are left out, so an element keeps whatever
presentation attribute it already had. `<script>` is not run. Interpolating the
`d` attribute is not supported; those animations switch between values instead
of morphing.

Filters are not supported at all, animated or otherwise, because the
`vector_graphics` renderer underneath drops `<filter>` entirely. An SVG that
relies on one still draws, just without the effect. The same renderer knows the
fifteen CSS blend modes but not `plus-lighter`, which editors reach for when
they want a glow.

If you need filters, path morphing, or `<script>`, look at
[`full_svg_flutter`](https://pub.dev/packages/full_svg_flutter), which covers
considerably more of the format at the cost of a heavier dependency set.

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

`AnimatedSvgFrames` reports `frameCount` and `compiledByteSize`, so an animation
can say what it costs rather than being guessed at.

- `frameRate` (default `60`) — frames compiled per second of animation.
- `maxFrames` (default `300`) — ceiling; longer animations are sampled at a
  lower rate rather than growing without bound.
- `placeholderBuilder` — shown while the animation compiles.
- `svgAnimateCache` — the shared cache of compiled animations. Lower its
  `maximumSize` (default 10) to trade recompilation for memory.

On the web there are no isolates, so compilation runs on the main thread; prefer
a lower `frameRate` for long animations there.

## License

BSD 3-Clause. Portions are derived from the Flutter project, which is
distributed under the same license.
