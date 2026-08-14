## 0.2.0

* Adds support for CSS motion paths: `offset-path: path(...)` driven by an
  animated `offset-distance`, with `offset-rotate`. This is how SVGator and
  similar tools express movement, so their exports now animate rather than
  scaling and rotating in place.
* Fixes `offset-distance` and the other `offset-*` properties being written
  back into the compiled markup as presentation attributes, where nothing
  could use them.

## 0.1.0

* Initial release.
