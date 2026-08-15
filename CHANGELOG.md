## 0.3.1

* Fixes a `@keyframes` rule that declares only `to` sitting still. The missing
  end was filled in from the value the element carried, and an element that
  carried none got the other keyframe instead, so both ends agreed and nothing
  moved. It now falls back to the value the property has outside the animation:
  no rotation for a transform, fully opaque for an opacity. This is how nearly
  every CSS spinner is written — `@keyframes spin { to { transform:
  rotate(360deg) } }` — so it did not turn.
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
