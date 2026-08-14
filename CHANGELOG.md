## 0.2.1

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
