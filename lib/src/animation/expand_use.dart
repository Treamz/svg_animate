import 'package:xml/xml.dart';

import 'values.dart';

/// Attributes of a `<use>` that describe the reference itself rather than the
/// element it produces.
const Set<String> _referenceAttributes = <String>{
  'href',
  // `width` and `height` on a `<use>` only mean anything when it references an
  // `<svg>` or a `<symbol>`, which an image is not.
  'width',
  'height',
  'x',
  'y',
};

/// Replaces every `<use>` that points at an `<image>` with the image itself.
///
/// The renderer underneath loses an image's size when it is reached through a
/// reference, and then refuses to draw something of zero width, which fails the
/// whole picture rather than just that element. Copying the image in sidesteps
/// that, at the cost of repeating whatever the image embeds.
///
/// Only images are expanded. A `<use>` that points at a shape or a group draws
/// correctly as it is, and copying those would grow the document for nothing.
void expandImageUses(XmlDocument document, Map<String, XmlElement> elementsById) {
  for (final XmlElement use in document.descendantElements.toList()) {
    if (use.name.local != 'use') {
      continue;
    }
    final XmlElement? target = _referencedElement(use, elementsById);
    if (target == null || target.name.local != 'image') {
      continue;
    }
    use.replace(_inline(use, target));
  }
}

XmlElement? _referencedElement(XmlElement use, Map<String, XmlElement> elementsById) {
  for (final XmlAttribute attribute in use.attributes) {
    if (attribute.name.local != 'href') {
      continue;
    }
    final String value = attribute.value.trim();
    if (value.startsWith('#')) {
      return elementsById[value.substring(1)];
    }
  }
  return null;
}

/// Builds the element that stands in for [use], carrying over everything the
/// reference contributed.
XmlElement _inline(XmlElement use, XmlElement image) {
  final XmlElement inlined = image.copy();
  inlined.removeAttribute('id');

  final transforms = <String>[];
  final String? useTransform = use.getAttribute('transform');
  if (useTransform != null && useTransform.trim().isNotEmpty) {
    transforms.add(useTransform.trim());
  }
  // `x` and `y` on a `<use>` translate what it draws.
  final double x = _length(use.getAttribute('x'));
  final double y = _length(use.getAttribute('y'));
  if (x != 0 || y != 0) {
    transforms.add('translate(${formatSvgNumber(x)} ${formatSvgNumber(y)})');
  }
  final String? imageTransform = inlined.getAttribute('transform');
  if (imageTransform != null && imageTransform.trim().isNotEmpty) {
    transforms.add(imageTransform.trim());
  }

  for (final XmlAttribute attribute in use.attributes) {
    if (_referenceAttributes.contains(attribute.name.local) ||
        attribute.name.local == 'transform') {
      continue;
    }
    inlined.setAttribute(attribute.name.qualified, attribute.value);
  }
  if (transforms.isNotEmpty) {
    inlined.setAttribute('transform', transforms.join(' '));
  }
  return inlined;
}

double _length(String? raw) {
  if (raw == null) {
    return 0;
  }
  final NumberListValue? value = NumberListValue.parse(raw);
  return value == null || value.numbers.isEmpty ? 0 : value.numbers.first;
}
