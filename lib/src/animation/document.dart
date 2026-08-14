import 'package:xml/xml.dart';

import 'animation.dart';
import 'css.dart';
import 'css_animations.dart';
import 'expand_use.dart';
import 'offset_path.dart';
import 'parsed_animation.dart';
import 'smil_parser.dart';
import 'values.dart';

/// The longest loop this package will build for a document whose animations
/// repeat indefinitely.
///
/// Animations with co-prime durations can have a combined loop that is
/// arbitrarily long, which would take an unbounded number of frames to
/// pre-compile. Past this point the loop restarts at the longest single
/// iteration instead, which is visually seamless for all but the animations
/// that were already out of step.
const Duration maxLoopDuration = Duration(seconds: 60);

/// An SVG document whose SMIL and CSS animations have been resolved, and which
/// can be sampled to the static SVG that should be drawn at a point in time.
///
/// Sampling produces plain SVG markup with no animation elements, so the result
/// can be handed to the ordinary vector_graphics compiler.
class AnimatedSvgDocument {
  AnimatedSvgDocument._(this._document, this._targets, this.duration, this.loops);

  /// Parses [source] and resolves the animations it declares.
  ///
  /// Throws an [XmlException] if [source] is not well formed XML, matching what
  /// callers already see for malformed SVG.
  factory AnimatedSvgDocument.parse(String source) {
    final document = XmlDocument.parse(source);
    final CssStylesheet stylesheet = _extractStylesheet(document);
    final elementsById = <String, XmlElement>{};
    for (final XmlElement element in document.descendantElements) {
      final String? id = element.getAttribute('id');
      if (id != null) {
        elementsById.putIfAbsent(id, () => element);
      }
    }

    expandImageUses(document, elementsById);

    final _ViewBox viewBox = _ViewBox.of(document.rootElement);
    final origins = <XmlElement, (double, double)>{};
    final animations = <ParsedAnimation>[];
    for (final XmlElement element in document.descendantElements.toList()) {
      if (smilAnimationElements.contains(element.name.local)) {
        continue;
      }
      final Map<String, String> declarations = _flattenStyle(element, stylesheet);
      if (declarations.isEmpty) {
        continue;
      }
      final String? rawOrigin = declarations['transform-origin'];
      if (rawOrigin != null && declarations['transform-box'] != 'fill-box') {
        final (double, double)? origin = _parseTransformOrigin(rawOrigin, viewBox);
        if (origin != null) {
          origins[element] = origin;
        }
      }
      final OffsetPath? offsetPath = OffsetPath.parse(declarations);
      var movesAlongPath = false;
      for (final CssAnimationSpec spec in parseCssAnimationSpecs(declarations)) {
        for (final SvgAttributeAnimation animation in buildCssAnimations(
          spec,
          stylesheet,
          element.getAttribute,
        )) {
          if (animation.attributeName == 'offset-distance') {
            // Only meaningful with a path to walk along; without one the
            // distance names nothing.
            if (offsetPath != null) {
              movesAlongPath = true;
              animations.add(ParsedAnimation(element, offsetPath.toTransformAnimation(animation)));
            }
            continue;
          }
          animations.add(ParsedAnimation(element, animation));
        }
      }
      if (offsetPath != null && !movesAlongPath) {
        // The element sits at a fixed point on its path rather than travelling
        // along it, which still has to be applied.
        _prependTransform(element, offsetPath.transformFor(declarations['offset-distance']));
      }
    }

    animations.addAll(
      parseSmilAnimations(
        document,
        elementsById: elementsById,
        baseValueOf: (XmlElement element, String attributeName) =>
            element.getAttribute(attributeName),
      ),
    );
    for (final XmlElement element in document.descendantElements.toList()) {
      if (smilAnimationElements.contains(element.name.local)) {
        element.remove();
      }
    }

    final targets = <_AnimationTarget>[];
    final targetsByKey = <(XmlElement, String), _AnimationTarget>{};
    for (final parsed in animations) {
      final (XmlElement, String) key = (parsed.target, parsed.animation.attributeName);
      final _AnimationTarget target = targetsByKey.putIfAbsent(key, () {
        final created = _AnimationTarget(
          parsed.target,
          parsed.animation.attributeName,
          origins[parsed.target],
        );
        targets.add(created);
        return created;
      });
      target.animations.add(parsed.animation);
    }

    // Elements that are not animated still need their transform origin folded
    // into their transform, which otherwise would rotate about the wrong point.
    for (final MapEntry<XmlElement, (double, double)> entry in origins.entries) {
      if (targetsByKey.containsKey((entry.key, 'transform'))) {
        continue;
      }
      final String? transform = entry.key.getAttribute('transform');
      if (transform != null && transform.trim().isNotEmpty) {
        entry.key.setAttribute('transform', _aboutOrigin(transform, entry.value));
      }
    }

    final _DocumentTiming timing = _documentTiming(targets);
    return AnimatedSvgDocument._(document, targets, timing.duration, timing.loops);
  }

  final XmlDocument _document;
  final List<_AnimationTarget> _targets;

  /// How long one full loop of the document takes.
  ///
  /// [Duration.zero] if the document declares no animation this package can
  /// run, in which case the document renders as a single static frame.
  final Duration duration;

  /// Whether the document is meant to repeat forever.
  ///
  /// False for documents whose animations all end, which should be played once
  /// and left on their final frame.
  final bool loops;

  /// Whether the document animates at all.
  bool get isAnimated => duration > Duration.zero;

  /// Returns the static SVG markup for the document at [time], measured from
  /// the start of the animation.
  String sampleAt(Duration time) {
    for (final _AnimationTarget target in _targets) {
      target.applyAt(time);
    }
    return _document.toXmlString();
  }
}

class _AnimationTarget {
  _AnimationTarget(this.element, this.attributeName, this.origin)
    : baseValue = element.getAttribute(attributeName) {
    final String? base = baseValue;
    baseParsed = base == null ? null : parseAnimationValue(attributeName, base);
  }

  final XmlElement element;
  final String attributeName;
  final String? baseValue;
  final (double, double)? origin;
  final animations = <SvgAttributeAnimation>[];

  late final AnimatableValue? baseParsed;

  void applyAt(Duration time) {
    AnimatableValue? current = baseParsed;
    var wroteAnything = false;
    for (final SvgAttributeAnimation animation in animations) {
      final AnimatableValue? value = animation.valueAt(time);
      if (value == null) {
        continue;
      }
      wroteAnything = true;
      if (!animation.additive || current == null) {
        current = value;
      } else if (animation.prependsToUnderlyingValue) {
        current = value.compose(current) ?? value;
      } else {
        current = current.compose(value) ?? value;
      }
    }

    if (!wroteAnything) {
      // Nothing is contributing, so restore exactly what the markup said rather
      // than a re-serialized copy of it.
      if (baseValue == null) {
        element.removeAttribute(attributeName);
      } else {
        element.setAttribute(attributeName, _withOrigin(baseValue!));
      }
      return;
    }
    final String text = _withOrigin(current!.toAttributeValue());
    element.setAttribute(attributeName, text);
  }

  String _withOrigin(String transform) =>
      attributeName == 'transform' && origin != null ? _aboutOrigin(transform, origin!) : transform;
}

/// Rewrites [transform] so that it is applied about [origin] rather than the
/// origin of the user coordinate system, which is what `transform-origin` asks
/// for.
String _aboutOrigin(String transform, (double, double) origin) {
  final String x = formatSvgNumber(origin.$1);
  final String y = formatSvgNumber(origin.$2);
  final String negativeX = formatSvgNumber(-origin.$1);
  final String negativeY = formatSvgNumber(-origin.$2);
  return 'translate($x $y) $transform translate($negativeX $negativeY)';
}

/// Applies [transform] outside whatever transform [element] already has.
void _prependTransform(XmlElement element, TransformListValue transform) {
  final String? existing = element.getAttribute('transform');
  final String text = transform.toAttributeValue();
  element.setAttribute(
    'transform',
    existing == null || existing.trim().isEmpty ? text : '$text $existing',
  );
}

CssStylesheet _extractStylesheet(XmlDocument document) {
  final styleElements = <XmlElement>[
    for (final XmlElement element in document.descendantElements)
      if (element.name.local == 'style') element,
  ];
  if (styleElements.isEmpty) {
    return CssStylesheet.empty;
  }
  final CssStylesheet stylesheet = CssStylesheet.parse(
    styleElements.map((XmlElement element) => element.innerText).join('\n'),
  );
  for (final element in styleElements) {
    element.remove();
  }
  return stylesheet;
}

/// Resolves the CSS that applies to [element] and writes it back as
/// presentation attributes.
///
/// The vector_graphics compiler does not implement CSS selectors, so folding
/// the cascade into attributes is what makes styled SVGs render at all. Inline
/// `style` attributes are folded in the same pass so that the value an
/// animation starts from is unambiguous.
///
/// Returns the resolved declarations, including the ones that describe
/// animations rather than appearance.
Map<String, String> _flattenStyle(XmlElement element, CssStylesheet stylesheet) {
  if (stylesheet.rules.isEmpty && element.getAttribute('style') == null) {
    return const <String, String>{};
  }
  final Map<String, String> declarations = stylesheet.declarationsFor(element);
  for (final MapEntry<String, String> entry in declarations.entries) {
    if (_canWriteAsAttribute(entry.key, entry.value)) {
      element.setAttribute(entry.key, entry.value);
    }
  }
  element.removeAttribute('style');
  return declarations;
}

/// A name that XML allows for an attribute.
///
/// CSS property names are ASCII, so this only has to cover the ASCII part of
/// the XML `Name` production.
final RegExp _xmlAttributeName = RegExp(r'^[A-Za-z_:][A-Za-z0-9_:.-]*$');

/// Whether a resolved declaration can be written back as a presentation
/// attribute.
///
/// Declarations that cannot be are left out rather than written anyway: a CSS
/// custom property is not a legal XML attribute name and would make the sampled
/// markup unparseable, and a value that references one cannot be resolved here,
/// so writing it would replace an attribute the compiler understands with one
/// it does not.
bool _canWriteAsAttribute(String property, String value) {
  return !nonPresentationProperties.contains(property) &&
      _xmlAttributeName.hasMatch(property) &&
      !value.contains('var(');
}

class _DocumentTiming {
  const _DocumentTiming(this.duration, this.loops);

  final Duration duration;
  final bool loops;
}

_DocumentTiming _documentTiming(List<_AnimationTarget> targets) {
  Duration longestFiniteEnd = Duration.zero;
  Duration longestIteration = Duration.zero;
  var loopMicroseconds = 1;
  var hasIndefinite = false;
  var hasAnimation = false;
  for (final target in targets) {
    for (final SvgAttributeAnimation animation in target.animations) {
      hasAnimation = true;
      final Duration? end = animation.activeEnd;
      final Duration simpleDuration = animation.timing.simpleDuration ?? Duration.zero;
      final Duration iterationEnd = animation.timing.begin + simpleDuration;
      if (iterationEnd > longestIteration) {
        longestIteration = iterationEnd;
      }
      if (end != null) {
        if (end > longestFiniteEnd) {
          longestFiniteEnd = end;
        }
        continue;
      }
      hasIndefinite = true;
      if (simpleDuration > Duration.zero) {
        loopMicroseconds = _leastCommonMultiple(loopMicroseconds, simpleDuration.inMicroseconds);
      }
    }
  }
  if (!hasAnimation) {
    return const _DocumentTiming(Duration.zero, false);
  }
  if (!hasIndefinite) {
    return _DocumentTiming(longestFiniteEnd, false);
  }
  if (loopMicroseconds <= 1 || loopMicroseconds > maxLoopDuration.inMicroseconds) {
    // Either nothing repeats on a usable period, or the combined period is
    // impractically long; fall back to the longest single iteration.
    return _DocumentTiming(
      longestIteration > Duration.zero ? longestIteration : longestFiniteEnd,
      true,
    );
  }
  // Extend the loop until it also covers every animation that does end, so a
  // one-shot intro is not cut off by a repeating background animation.
  final int target = longestFiniteEnd.inMicroseconds;
  var total = loopMicroseconds;
  while (total < target) {
    total += loopMicroseconds;
    if (total > maxLoopDuration.inMicroseconds) {
      break;
    }
  }
  return _DocumentTiming(Duration(microseconds: total), true);
}

int _leastCommonMultiple(int a, int b) {
  if (a == 0 || b == 0) {
    return a == 0 ? b : a;
  }
  return a ~/ _greatestCommonDivisor(a, b) * b;
}

int _greatestCommonDivisor(int a, int b) {
  int first = a.abs();
  int second = b.abs();
  while (second != 0) {
    final int remainder = first % second;
    first = second;
    second = remainder;
  }
  return first;
}

/// The reference box that `transform-origin` percentages resolve against.
class _ViewBox {
  const _ViewBox(this.x, this.y, this.width, this.height);

  static _ViewBox of(XmlElement root) {
    final NumberListValue? viewBox = NumberListValue.parse(root.getAttribute('viewBox') ?? '');
    if (viewBox != null && viewBox.numbers.length == 4) {
      final List<double> numbers = viewBox.numbers;
      return _ViewBox(numbers[0], numbers[1], numbers[2], numbers[3]);
    }
    final NumberListValue? width = NumberListValue.parse(root.getAttribute('width') ?? '');
    final NumberListValue? height = NumberListValue.parse(root.getAttribute('height') ?? '');
    return _ViewBox(0, 0, width?.numbers.first ?? 0, height?.numbers.first ?? 0);
  }

  final double x;
  final double y;
  final double width;
  final double height;
}

const Map<String, double> _horizontalOriginKeywords = <String, double>{
  'left': 0,
  'center': 0.5,
  'right': 1,
};

const Map<String, double> _verticalOriginKeywords = <String, double>{
  'top': 0,
  'center': 0.5,
  'bottom': 1,
};

/// Resolves a `transform-origin` value against [viewBox], which is the
/// reference box for SVG elements unless `transform-box` says otherwise.
(double, double)? _parseTransformOrigin(String raw, _ViewBox viewBox) {
  final List<String> tokens = splitCssTokens(raw.toLowerCase());
  if (tokens.isEmpty || tokens.length > 3) {
    return null;
  }
  String horizontal = tokens.first;
  String vertical = tokens.length > 1 ? tokens[1] : 'center';
  // `transform-origin: top left` is legal, so keywords may arrive swapped.
  if (_verticalOriginKeywords.containsKey(horizontal) &&
      !_horizontalOriginKeywords.containsKey(horizontal)) {
    final swapped = horizontal;
    horizontal = vertical;
    vertical = swapped;
  }
  final double? x = _resolveOriginComponent(
    horizontal,
    _horizontalOriginKeywords,
    viewBox.x,
    viewBox.width,
  );
  final double? y = _resolveOriginComponent(
    vertical,
    _verticalOriginKeywords,
    viewBox.y,
    viewBox.height,
  );
  return x == null || y == null ? null : (x, y);
}

double? _resolveOriginComponent(
  String token,
  Map<String, double> keywords,
  double origin,
  double size,
) {
  final double? keyword = keywords[token];
  if (keyword != null) {
    return origin + size * keyword;
  }
  final NumberListValue? value = NumberListValue.parse(token);
  if (value == null || value.numbers.length != 1) {
    return null;
  }
  switch (value.unit) {
    case '%':
      return origin + size * value.numbers.first / 100;
    case '':
    case 'px':
      return value.numbers.first;
    default:
      return null;
  }
}
