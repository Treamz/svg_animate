import 'package:flutter/animation.dart';

import 'animation.dart';
import 'css.dart';
import 'timing.dart';
import 'values.dart';

/// CSS properties that describe an animation rather than the appearance of an
/// element, and so are never written back as presentation attributes.
const Set<String> nonPresentationProperties = <String>{
  'animation',
  'animation-delay',
  'animation-direction',
  'animation-duration',
  'animation-fill-mode',
  'animation-iteration-count',
  'animation-name',
  'animation-play-state',
  'animation-timing-function',
  'offset',
  'offset-anchor',
  'offset-distance',
  'offset-path',
  'offset-position',
  'offset-rotate',
  'transform-box',
  'transform-origin',
  'transition',
  'transition-delay',
  'transition-duration',
  'transition-property',
  'transition-timing-function',
  'will-change',
};

/// Properties that may appear inside a `@keyframes` block but describe the
/// animation rather than being animated by it.
///
/// Everything else in a keyframe is a value to animate, including properties
/// such as `offset-distance` that are never written back as attributes.
const Set<String> _keyframeControlProperties = <String>{
  'animation',
  'animation-delay',
  'animation-direction',
  'animation-duration',
  'animation-fill-mode',
  'animation-iteration-count',
  'animation-name',
  'animation-play-state',
  'animation-timing-function',
};

const Set<String> _directionKeywords = <String>{
  'normal',
  'reverse',
  'alternate',
  'alternate-reverse',
};

const Set<String> _fillModeKeywords = <String>{'none', 'forwards', 'backwards', 'both'};

const Set<String> _playStateKeywords = <String>{'running', 'paused'};

const Set<String> _timingFunctionKeywords = <String>{
  'linear',
  'ease',
  'ease-in',
  'ease-out',
  'ease-in-out',
  'step-start',
  'step-end',
};

final RegExp _cssTimePattern = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)(ms|s)$');

/// The properties of a single entry of the CSS `animation` shorthand.
class CssAnimationSpec {
  /// Creates a specification with CSS's initial values.
  CssAnimationSpec();

  /// The `@keyframes` name to run.
  String? name;

  /// How long one iteration lasts.
  Duration duration = Duration.zero;

  /// How long to wait before the first iteration.
  Duration delay = Duration.zero;

  /// How many iterations to run, or null for `infinite`.
  double? iterationCount = 1;

  /// The easing applied across each iteration.
  Curve timingFunction = Curves.linear;

  /// Which way round each iteration runs.
  SvgAnimationDirection direction = SvgAnimationDirection.normal;

  /// Whether the animation holds its final value.
  SvgFillMode fill = SvgFillMode.remove;

  /// Whether the animation is paused, in which case it never advances.
  bool paused = false;
}

/// Reads the `animation` shorthand and longhand declarations out of
/// [declarations].
///
/// Returns one specification per comma separated entry of the shorthand.
List<CssAnimationSpec> parseCssAnimationSpecs(Map<String, String> declarations) {
  final specs = <CssAnimationSpec>[];
  final String? shorthand = declarations['animation'];
  if (shorthand != null) {
    for (final String entry in splitCssList(shorthand)) {
      specs.add(_parseShorthandEntry(entry));
    }
  }

  final List<String> names = _longhandList(declarations, 'animation-name');
  if (specs.isEmpty && names.isEmpty) {
    return const <CssAnimationSpec>[];
  }
  while (specs.length < names.length) {
    specs.add(CssAnimationSpec());
  }

  void applyLonghand(String property, void Function(CssAnimationSpec spec, String value) apply) {
    final List<String> values = _longhandList(declarations, property);
    if (values.isEmpty) {
      return;
    }
    for (var i = 0; i < specs.length; i += 1) {
      apply(specs[i], values[i % values.length]);
    }
  }

  applyLonghand('animation-name', (CssAnimationSpec spec, String value) {
    spec.name = value == 'none' ? null : value;
  });
  applyLonghand('animation-duration', (CssAnimationSpec spec, String value) {
    spec.duration = parseCssTime(value) ?? spec.duration;
  });
  applyLonghand('animation-delay', (CssAnimationSpec spec, String value) {
    spec.delay = parseCssTime(value) ?? spec.delay;
  });
  applyLonghand('animation-iteration-count', (CssAnimationSpec spec, String value) {
    spec.iterationCount = value == 'infinite' ? null : double.tryParse(value) ?? 1;
  });
  applyLonghand('animation-timing-function', (CssAnimationSpec spec, String value) {
    spec.timingFunction = parseCssTimingFunction(value);
  });
  applyLonghand('animation-direction', (CssAnimationSpec spec, String value) {
    spec.direction = _parseDirection(value) ?? spec.direction;
  });
  applyLonghand('animation-fill-mode', (CssAnimationSpec spec, String value) {
    spec.fill = _parseFillMode(value);
  });
  applyLonghand('animation-play-state', (CssAnimationSpec spec, String value) {
    spec.paused = value == 'paused';
  });

  return specs;
}

CssAnimationSpec _parseShorthandEntry(String entry) {
  final spec = CssAnimationSpec();
  var sawDuration = false;
  var sawIterationCount = false;
  for (final String token in splitCssTokens(entry)) {
    final String value = token.toLowerCase();
    final Duration? time = parseCssTime(value);
    if (time != null) {
      if (sawDuration) {
        spec.delay = time;
      } else {
        spec.duration = time;
        sawDuration = true;
      }
      continue;
    }
    if (value == 'infinite') {
      spec.iterationCount = null;
      sawIterationCount = true;
      continue;
    }
    final double? count = double.tryParse(value);
    if (count != null && !sawIterationCount) {
      spec.iterationCount = count;
      sawIterationCount = true;
      continue;
    }
    if (_directionKeywords.contains(value)) {
      spec.direction = _parseDirection(value)!;
      continue;
    }
    if (_playStateKeywords.contains(value)) {
      spec.paused = value == 'paused';
      continue;
    }
    if (_fillModeKeywords.contains(value)) {
      spec.fill = _parseFillMode(value);
      continue;
    }
    if (_timingFunctionKeywords.contains(value) ||
        value.startsWith('cubic-bezier(') ||
        value.startsWith('steps(')) {
      spec.timingFunction = parseCssTimingFunction(value);
      continue;
    }
    spec.name ??= token;
  }
  return spec;
}

SvgAnimationDirection? _parseDirection(String value) {
  switch (value) {
    case 'normal':
      return SvgAnimationDirection.normal;
    case 'reverse':
      return SvgAnimationDirection.reverse;
    case 'alternate':
      return SvgAnimationDirection.alternate;
    case 'alternate-reverse':
      return SvgAnimationDirection.alternateReverse;
    default:
      return null;
  }
}

SvgFillMode _parseFillMode(String value) =>
    value == 'forwards' || value == 'both' ? SvgFillMode.freeze : SvgFillMode.remove;

List<String> _longhandList(Map<String, String> declarations, String property) {
  final String? value = declarations[property];
  return value == null ? const <String>[] : splitCssList(value);
}

/// Parses a CSS `<time>`, which unlike a SMIL clock value must carry a unit.
Duration? parseCssTime(String raw) {
  final String value = raw.trim().toLowerCase();
  if (!_cssTimePattern.hasMatch(value)) {
    return null;
  }
  return parseClockValue(value);
}

/// Splits a comma separated CSS value list, ignoring commas inside functions.
List<String> splitCssList(String value) => _split(value, isSeparator: (String c) => c == ',');

/// Splits a CSS value into whitespace separated tokens, keeping functions such
/// as `cubic-bezier(0, 0, 1, 1)` intact.
List<String> splitCssTokens(String value) =>
    _split(value, isSeparator: (String c) => c.trim().isEmpty);

List<String> _split(String value, {required bool Function(String character) isSeparator}) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var depth = 0;
  for (var i = 0; i < value.length; i += 1) {
    final String character = value[i];
    if (character == '(') {
      depth += 1;
    } else if (character == ')') {
      depth -= 1;
    }
    if (depth <= 0 && isSeparator(character)) {
      if (buffer.isNotEmpty) {
        parts.add(buffer.toString());
        buffer.clear();
      }
      continue;
    }
    buffer.write(character);
  }
  if (buffer.isNotEmpty) {
    parts.add(buffer.toString());
  }
  return parts.map((String part) => part.trim()).where((String part) => part.isNotEmpty).toList();
}

/// Builds the animations described by [spec] from the matching `@keyframes`
/// rule in [stylesheet].
///
/// [baseValueOf] supplies the value a property has outside the animation, which
/// fills in any keyframe list that does not start at 0% or end at 100%.
List<SvgAttributeAnimation> buildCssAnimations(
  CssAnimationSpec spec,
  CssStylesheet stylesheet,
  String? Function(String property) baseValueOf,
) {
  final String? name = spec.name;
  if (name == null || spec.paused || spec.duration <= Duration.zero) {
    return const <SvgAttributeAnimation>[];
  }
  final CssKeyframes? keyframes = stylesheet.keyframes[name];
  if (keyframes == null) {
    return const <SvgAttributeAnimation>[];
  }

  // Collect every property mentioned anywhere in the rule, then build one
  // animation per property out of the stops that mention it.
  final stops = <String, Map<double, String>>{};
  final stopCurves = <double, Curve>{};
  for (final CssKeyframe keyframe in keyframes.keyframes) {
    final String? timingFunction = keyframe.declarations['animation-timing-function']?.value;
    for (final double offset in keyframe.offsets) {
      if (offset < 0 || offset > 1) {
        continue;
      }
      if (timingFunction != null) {
        stopCurves[offset] = parseCssTimingFunction(timingFunction);
      }
      for (final MapEntry<String, CssDeclaration> entry in keyframe.declarations.entries) {
        if (_keyframeControlProperties.contains(entry.key)) {
          continue;
        }
        (stops[entry.key] ??= <double, String>{})[offset] = entry.value.value;
      }
    }
  }

  final animations = <SvgAttributeAnimation>[];
  for (final MapEntry<String, Map<double, String>> entry in stops.entries) {
    final SvgAttributeAnimation? animation = _buildPropertyAnimation(
      entry.key,
      entry.value,
      stopCurves,
      spec,
      baseValueOf(entry.key),
    );
    if (animation != null) {
      animations.add(animation);
    }
  }
  return animations;
}

/// The value [property] has when the animation is not running.
///
/// That is what a `@keyframes` rule means by leaving 0% or 100% out, and
/// getting it wrong is what makes `@keyframes spin { to { transform:
/// rotate(360deg) } }` — the way nearly every CSS spinner is written — sit
/// still: with nothing to start from, both ends of the animation say 360.
///
/// [declared] is the value at the end that was written, and is used for its
/// shape, since a transform can only interpolate against one built the same way.
AnimatableValue _outsideTheAnimation(String property, String? baseValue, AnimatableValue declared) {
  if (baseValue != null) {
    final AnimatableValue? parsed = property == 'transform'
        ? TransformListValue.parse(baseValue)
        : parseAnimatableValue(property, baseValue);
    if (parsed != null) {
      return parsed;
    }
  }
  // No value of its own, so the property's initial value stands in.
  if (declared is TransformListValue) {
    return declared.toIdentity();
  }
  if (_opaqueByDefault.contains(property)) {
    return const NumberListValue(<double>[1]);
  }
  // Nothing better to say than that it does not change.
  return declared;
}

/// Properties whose initial value is 1 rather than 0, so that leaving out a
/// keyframe means fully opaque rather than invisible.
const Set<String> _opaqueByDefault = <String>{
  'fill-opacity',
  'opacity',
  'stop-opacity',
  'stroke-opacity',
};

SvgAttributeAnimation? _buildPropertyAnimation(
  String property,
  Map<double, String> stops,
  Map<double, Curve> stopCurves,
  CssAnimationSpec spec,
  String? baseValue,
) {
  final List<double> offsets = stops.keys.toList()..sort();
  if (offsets.isEmpty) {
    return null;
  }

  final values = <AnimatableValue>[];
  for (final double offset in offsets) {
    final AnimatableValue? value = property == 'transform'
        ? TransformListValue.parse(stops[offset]!)
        : parseAnimatableValue(property, stops[offset]!);
    if (value == null) {
      return null;
    }
    values.add(value);
  }

  // A keyframe list that does not cover the whole range takes the end it left
  // out from the value the property has outside the animation.
  if (offsets.first > 0) {
    offsets.insert(0, 0);
    values.insert(0, _outsideTheAnimation(property, baseValue, values.first));
  }
  if (offsets.last < 1) {
    offsets.add(1);
    values.add(_outsideTheAnimation(property, baseValue, values.last));
  }
  if (values.length < 2) {
    return null;
  }

  return SvgAttributeAnimation(
    attributeName: property,
    values: values,
    keyTimes: offsets,
    calcMode: SvgCalcMode.spline,
    keySplines: <Curve>[
      for (var i = 0; i < values.length - 1; i += 1) stopCurves[offsets[i]] ?? spec.timingFunction,
    ],
    timing: SvgAnimationTiming(
      begin: spec.delay,
      simpleDuration: spec.duration,
      repeatCount: spec.iterationCount,
      fill: spec.fill,
      direction: spec.direction,
    ),
  );
}
