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
  'transform-box',
  'transform-origin',
  'transition',
  'transition-delay',
  'transition-duration',
  'transition-property',
  'transition-timing-function',
  'will-change',
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
        if (nonPresentationProperties.contains(entry.key)) {
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

  final rawValues = <String>[for (final double offset in offsets) stops[offset]!];
  // A keyframe list that does not cover the whole range falls back to the value
  // the element has outside the animation, or, failing that, holds the nearest
  // declared value.
  if (offsets.first > 0) {
    offsets.insert(0, 0);
    rawValues.insert(0, baseValue ?? rawValues.first);
  }
  if (offsets.last < 1) {
    offsets.add(1);
    rawValues.add(baseValue ?? rawValues.last);
  }

  final values = <AnimatableValue>[];
  for (final raw in rawValues) {
    final AnimatableValue? value = property == 'transform'
        ? TransformListValue.parse(raw)
        : parseAnimatableValue(property, raw);
    if (value == null) {
      return null;
    }
    values.add(value);
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
