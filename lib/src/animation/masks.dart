import 'package:xml/xml.dart';

/// Puts an opaque black backing under the content of every luminance mask.
///
/// `vector_graphics` draws a mask into a layer and turns it into coverage with
/// a colour matrix that reads the luminance of each pixel's colour and ignores
/// its alpha. Flutter hands that matrix colours that are not premultiplied, so
/// a white pixel at 30% opacity reads as white: fully covering. Anything
/// translucent in a mask, a `fill-opacity` fade or an `opacity`, comes out
/// opaque, and so does the soft edge of every antialiased shape in it, which
/// makes mask edges hard.
///
/// SVG reads a luminance mask as luminance times alpha, which is the same as
/// the luminance of the mask drawn over black. So the mask is drawn over black
/// here: every pixel in the layer is then opaque, its colour already carries
/// its coverage, and the matrix reads it correctly. Black reads as nothing, so
/// what the backing adds outside the mask's own content is no coverage, which
/// is what was there before.
///
/// Masks with `mask-type="alpha"` are left alone; the renderer reads those as
/// luminance too, and a backing would not change that.
///
/// The right fix is a premultiplied read in `vector_graphics`' `onMask`, which
/// would also reach still SVGs drawn through `flutter_svg`.
void backMasks(XmlDocument document) {
  for (final XmlElement mask in document.findAllElements('mask').toList()) {
    if (mask.getAttribute('mask-type')?.trim() == 'alpha') {
      continue;
    }
    final bool boundingBox = mask.getAttribute('maskContentUnits')?.trim() == 'objectBoundingBox';
    // Far past any mask region: the region clips the mask anyway, and
    // anything outside it covers nothing.
    final String start = boundingBox ? '-100' : '-100000';
    final String size = boundingBox ? '201' : '200001';
    final backing = XmlElement.tag('rect')
      ..setAttribute('x', start)
      ..setAttribute('y', start)
      ..setAttribute('width', size)
      ..setAttribute('height', size)
      ..setAttribute('fill', '#000');
    mask.children.insert(0, backing);
  }
}
