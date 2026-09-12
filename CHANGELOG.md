## 0.3.7

* Keeps a rounded rectangle's corner radius inside the size it is drawn at. SVG
  clamps a radius larger than half the side it rounds down to half that side, so
  a rect of zero width draws nothing; `vector_graphics_compiler` uses the radius
  as authored, and the two rounded ends cross over one another into a bow tie.
  Anything that grows a rounded bar from nothing showed it — including the
  progress bar in this package's own example and in its README — for as long as
  the bar was narrower than twice its radius. Worth fixing in flutter/packages
  too, where it would also fix still SVGs drawn through `flutter_svg`; the code
  here can only reach what it compiles itself.

## 0.3.6

* Says what an SVG asked for that will not happen, instead of leaving it to be
  deduced. An animation that does not play looks exactly like one that has not
  started: a still picture and no error, whatever the reason. Every compiled
  animation now carries `diagnostics`, and a debug build prints them the first
  time the SVG is compiled. Five things get reported: a document with no
  animation in it, and whether it carries a `<script>` that an editor exported
  its animation into; an animation whose every frame drew the same picture,
  which is what a morphing `d` does; an `<image>` pointing anywhere other than a
  `data:` URI, which the compiler leaves out of every frame without complaining;
  a `<filter>`, which is not drawn; and an animation sampled below the frame
  rate asked for because `maxFrames` would not stretch that far. Set
  `svgAnimateReportDiagnostics` to false to silence the printing.

* Publishes for the web again, and for WebAssembly with it. `dart:io` was
  imported for the file loader's `File`, and an import of it anywhere in the
  library is enough for the whole package to be analysed as not supporting the
  web: pub.dev listed five platforms while the README promised six and described
  what the package does on the sixth. That import now resolves to a stand-in
  where there is no `dart:io`, the way `flutter_svg` does it. Nothing about
  behaviour changes — a web build already compiled — and a file loader still
  cannot be built on the web, because there are still no files there.
* Documents `AnimationCache.maximumSizeBytes`, `currentSizeBytes` and
  `AnimatedSvgFrames.distinctFrameCount` in the README, which went on describing
  the cache as bounded by a count of entries alone: the model 0.3.4 replaced
  precisely because a count says so little about how much memory is held.

## 0.3.5

* Keeps one copy of any frame that repeats, rather than one per sampling point.
  Frames repeat whenever the document holds still — a `<set>`, a discrete
  `calcMode`, a CSS `steps()` timing function, a long gap between keyframes — so
  a one-second blink compiled at the default frame rate held sixty pictures
  where it draws two, and a `steps(4)` slide held sixty where it draws four.
  Nothing changes for an animation whose frames all differ: the compiled size of
  a 450x450 banner is unchanged to the byte, and the extra pass over its 300
  frames does not measurably lengthen its 2.6 s compile.
* Stops playing an animation that never changes what it draws. A document can
  declare an animation the renderer cannot express — a morphing `d`, say — which
  sampled to sixty identical pictures, reported itself as animated, and ran a
  ticker that repainted the same picture for as long as the widget was on
  screen. `AnimatedSvgFrames.isAnimated` now counts pictures rather than
  sampling points, so nothing is started. `distinctFrameCount` reports how many
  there are, next to `frameCount`, which keeps its meaning as the resolution the
  timeline was sampled at.

## 0.3.4

* Bounds the animation cache by how much it is holding and not only by how many
  animations it holds, through `AnimationCache.maximumSizeBytes`, which defaults
  to 20 MiB. The count was the only limit, and how much an animation costs to
  hold has very little to do with how many there are: a spinner compiles to a
  few kilobytes and a banner carrying embedded bitmaps to several megabytes, so
  the default of ten entries was somewhere between 50 KB and 50 MB depending
  entirely on what an app happened to show. An animation larger than the whole
  budget is still kept, alone, rather than refused — refusing it would disable
  the cache for exactly the files whose recompilation is measured in seconds.
  `AnimationCache.currentSizeBytes` reports what is held.

## 0.3.3

* Shows the first frame while the rest are still being compiled, instead of a
  placeholder. Compiling every frame of a long animation is what the wait
  before it appears is made of, and the first frame alone is a fraction of that
  work: a 450x450 banner with embedded bitmaps now puts a picture on screen
  after 189 ms rather than 2.4 s, and starts moving once the rest arrive. The
  extra pass costs about 8% more total work on that file. Pictures waiting on
  the same animation share the first-frame pass between them, and an animation
  that is already compiled skips it altogether.
* Adds `AnimationCache`'s `[]` operator, which reports what is already compiled
  without compiling anything.

## 0.3.2

* Fixes a `@keyframes` rule that declares only `to` sitting still. The missing
  end was filled in from the value the element carried, and an element that
  carried none got the other keyframe instead, so both ends agreed and nothing
  moved. It now falls back to the value the property has outside the animation:
  no rotation for a transform, fully opaque for an opacity. This is how nearly
  every CSS spinner is written — `@keyframes spin { to { transform:
  rotate(360deg) } }` — so it did not turn.

## 0.3.1

* Adds `compileAnimatedSvg`, which compiles an animation without showing it.
  `AnimatedSvgFrames` could report `frameCount` and `compiledByteSize` but there
  was no way to get hold of one, so an SVG that embeds raster images could not
  be measured before choosing a frame rate for it.

## 0.3.0

* Stores what the compiled frames have in common once instead of in every frame.
  Consecutive frames describe the same document with a few numbers changed, and
  anything the SVG embeds sits at the front of each of them unchanged, so the
  run of bytes they all begin with is kept once and rebuilt into a frame when it
  is asked for. On a 450x450 banner carrying five embedded bitmaps this took the
  compiled animation from 27.5 MB to 5.1 MB at the default frame rate, and cost
  0.1 ms per frame change to put back together. SVGs that embed nothing are
  unaffected either way.
* **Breaking:** `AnimatedSvgFrames.frames` is replaced by `frameCount` and
  `frameAt`, since the frames are no longer held whole. `compiledByteSize`
  reports how much memory they take, which is worth checking before raising
  `frameRate` on an image-heavy SVG.


* Decodes an image embedded in an animated SVG once for the whole animation
  instead of once per frame. The renderer namespaces its image cache by the hash
  code of the loader it is handed, and every frame was handing it a different
  one. On a 450x450 banner carrying five embedded bitmaps this took the cost of
  a frame change from 6.8 ms to 1.4 ms, which is what an SVG with no images at
  all costs.

## 0.2.0

* Adds support for CSS motion paths: `offset-path: path(...)` driven by an
  animated `offset-distance`, with `offset-rotate`. This is how SVGator and
  similar tools express movement, so their exports now animate rather than
  scaling and rotating in place.
* Expands a `<use>` that points at an `<image>` into the image itself. The
  renderer loses an image's size when it is reached through a reference and then
  refuses to draw it, which failed the whole picture rather than that one
  element; SVG editors emit this shape whenever an image is placed more than
  once.
* Fixes `offset-distance` and the other `offset-*` properties being written
  back into the compiled markup as presentation attributes, where nothing
  could use them.

## 0.1.0

* Initial release.
