import 'package:xml/xml.dart';

/// The elements whose own `opacity` the compiler folds into their paint.
///
/// A group's `opacity` becomes a layer and works; these are the leaves.
const Set<String> _paintedElements = <String>{
  'path',
  'line',
  'polyline',
  'polygon',
  'rect',
  'circle',
  'ellipse',
  'text',
};

/// Shapes whose own `opacity` would be lost on a stroke they inherit.
///
/// `vector_graphics_compiler` has no layer for a shape's `opacity`: it
/// multiplies it into the shape's fill and stroke colours. For the stroke that
/// only happens when the shape names its own stroke colour. A shape that takes
/// its stroke from a group draws it at full strength whatever its `opacity`
/// says, even with a `stroke-opacity` of its own. Icon sets set the stroke
/// once on a group and hide a path with `opacity="0"` until a `<set>` shows
/// it, so the path was drawn from the first frame.
///
/// Writing the inherited stroke onto the shape makes it the shape's own, which
/// the compiler then fades. An inherited `stroke-opacity` is written alongside
/// it, because a shape's own stroke opacity replaces its parent's there rather
/// than combining with it.
///
/// The fix in the compiler is a couple of lines in `_parseStrokeAttributes`,
/// and would reach still SVGs drawn through `flutter_svg` too.
class InheritedStrokes {
  InheritedStrokes._(this._shapes);

  /// Finds the shapes in [document] that have, or may be animated to have, an
  /// `opacity` of their own.
  factory InheritedStrokes.find(XmlDocument document, Set<XmlElement> opacityTargets) {
    return InheritedStrokes._(<XmlElement>[
      for (final XmlElement element in document.descendantElements)
        if (_paintedElements.contains(element.name.local) &&
            (element.getAttribute('opacity') != null || opacityTargets.contains(element)))
          element,
    ]);
  }

  final List<XmlElement> _shapes;

  /// Whether there is anything to do at all.
  bool get isEmpty => _shapes.isEmpty;

  /// Writes the inherited stroke onto each shape that needs it for the values
  /// the document holds now, and returns what puts the document back.
  ///
  /// The document is shared between frames, and whether a shape has an
  /// opacity, or what its group's stroke is, can change from one to the next.
  void Function() apply() {
    final added = <(XmlElement, String)>[];
    for (final XmlElement shape in _shapes) {
      if (shape.getAttribute('opacity') == null || shape.getAttribute('stroke') != null) {
        continue;
      }
      final String? stroke = _inherited(shape.parent, 'stroke');
      if (stroke == null || stroke == 'none') {
        continue;
      }
      shape.setAttribute('stroke', stroke);
      added.add((shape, 'stroke'));
      if (shape.getAttribute('stroke-opacity') == null) {
        final String? strokeOpacity = _inherited(shape.parent, 'stroke-opacity');
        if (strokeOpacity != null) {
          shape.setAttribute('stroke-opacity', strokeOpacity);
          added.add((shape, 'stroke-opacity'));
        }
      }
    }
    return () {
      for (final (XmlElement shape, String name) in added) {
        shape.removeAttribute(name);
      }
    };
  }
}

String? _inherited(XmlNode? node, String name) {
  for (; node is XmlElement; node = node.parent) {
    final String? value = node.getAttribute(name)?.trim();
    if (value != null && value != 'inherit') {
      return value;
    }
  }
  return null;
}
