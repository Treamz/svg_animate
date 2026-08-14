import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:xml/xml.dart';

import 'animation.dart';
import 'motion_path.dart';
import 'parsed_animation.dart';
import 'timing.dart';
import 'values.dart';

/// The names of the SMIL animation elements this package understands.
const Set<String> smilAnimationElements = <String>{
  'animate',
  'animateTransform',
  'animateMotion',
  'set',
};

/// How many points are taken along an `<animateMotion>` path.
///
/// The samples are evenly spaced by arc length, so linear interpolation between
/// them follows the path closely without needing to evaluate it at draw time.
const int _motionPathSamples = 48;

/// Reads an attribute by its local name, so that both `href` and `xlink:href`
/// resolve to the same value.
String? attributeByLocalName(XmlElement element, String name) {
  for (final XmlAttribute attribute in element.attributes) {
    if (attribute.name.local == name) {
      return attribute.value;
    }
  }
  return null;
}

/// Parses every SMIL animation element in [document].
///
/// [elementsById] is used to resolve `href` and `<mpath>` references, and
/// [baseValueOf] supplies the underlying value of an attribute for animations
/// that only declare a `to` or `by` value.
///
/// Animation elements that cannot run, such as those with an event based
/// `begin`, are skipped.
List<ParsedAnimation> parseSmilAnimations(
  XmlDocument document, {
  required Map<String, XmlElement> elementsById,
  required String? Function(XmlElement element, String attributeName) baseValueOf,
}) {
  final animations = <ParsedAnimation>[];
  for (final XmlElement element in document.descendantElements) {
    if (!smilAnimationElements.contains(element.name.local)) {
      continue;
    }
    final XmlElement? target = _resolveTarget(element, elementsById);
    if (target == null) {
      continue;
    }
    final SvgAttributeAnimation? animation = _parseAnimationElement(
      element,
      target,
      elementsById,
      baseValueOf,
    );
    if (animation != null) {
      animations.add(ParsedAnimation(target, animation));
    }
  }
  return animations;
}

XmlElement? _resolveTarget(XmlElement element, Map<String, XmlElement> elementsById) {
  final String? href = attributeByLocalName(element, 'href');
  if (href != null && href.startsWith('#')) {
    return elementsById[href.substring(1)];
  }
  final XmlNode? parent = element.parent;
  return parent is XmlElement ? parent : null;
}

SvgAttributeAnimation? _parseAnimationElement(
  XmlElement element,
  XmlElement target,
  Map<String, XmlElement> elementsById,
  String? Function(XmlElement element, String attributeName) baseValueOf,
) {
  final String elementName = element.name.local;
  final isMotion = elementName == 'animateMotion';
  final isTransform = elementName == 'animateTransform';
  final String attributeName = isMotion || isTransform
      ? 'transform'
      : attributeByLocalName(element, 'attributeName')?.trim() ?? '';
  if (attributeName.isEmpty) {
    return null;
  }

  final SvgAnimationTiming? timing = _parseTiming(element, isSet: elementName == 'set');
  if (timing == null) {
    return null;
  }

  final additive = attributeByLocalName(element, 'additive')?.trim() == 'sum';
  final accumulate = attributeByLocalName(element, 'accumulate')?.trim() == 'sum';

  if (isMotion) {
    return _parseMotion(element, elementsById, timing, accumulate: accumulate);
  }

  final String? transformType = isTransform
      ? attributeByLocalName(element, 'type')?.trim() ?? 'translate'
      : null;
  final List<AnimatableValue>? values = _parseValues(
    element,
    target,
    attributeName,
    transformType,
    baseValueOf,
    isSet: elementName == 'set',
  );
  if (values == null || values.isEmpty) {
    return null;
  }

  SvgCalcMode calcMode = _parseCalcMode(element, defaultMode: SvgCalcMode.linear);
  if (elementName == 'set') {
    calcMode = SvgCalcMode.discrete;
  }

  List<double> keyTimes =
      _parseKeyTimes(element, values.length) ??
      (calcMode == SvgCalcMode.discrete
          ? discreteKeyTimes(values.length)
          : evenKeyTimes(values.length));
  List<Curve>? keySplines;
  if (calcMode == SvgCalcMode.paced) {
    keyTimes = pacedKeyTimes(values) ?? evenKeyTimes(values.length);
    calcMode = SvgCalcMode.linear;
  } else if (calcMode == SvgCalcMode.spline) {
    keySplines = _parseKeySplines(element, values.length - 1);
    if (keySplines == null) {
      calcMode = SvgCalcMode.linear;
    }
  }

  return SvgAttributeAnimation(
    attributeName: attributeName,
    values: values,
    keyTimes: keyTimes,
    timing: timing,
    calcMode: calcMode,
    keySplines: keySplines,
    additive: additive,
    accumulate: accumulate,
  );
}

SvgAttributeAnimation? _parseMotion(
  XmlElement element,
  Map<String, XmlElement> elementsById,
  SvgAnimationTiming timing, {
  required bool accumulate,
}) {
  String? pathData = attributeByLocalName(element, 'path');
  if (pathData == null) {
    for (final XmlElement child in element.childElements) {
      if (child.name.local != 'mpath') {
        continue;
      }
      final String? href = attributeByLocalName(child, 'href');
      if (href != null && href.startsWith('#')) {
        pathData = elementsById[href.substring(1)]?.getAttribute('d');
      }
    }
  }
  if (pathData == null) {
    return null;
  }
  final MotionPath? path = MotionPath.parse(pathData);
  if (path == null) {
    return null;
  }

  final String rotate = attributeByLocalName(element, 'rotate')?.trim() ?? '0';
  final double? fixedRotation = double.tryParse(rotate);
  // A heading that tracks the path passes through zero on any horizontal
  // stretch. The rotation is written out even then, so that every keyframe has
  // the same shape and can be interpolated; dropping it would make the samples
  // either side of such a stretch incompatible, and the motion would step
  // rather than move.
  final bool tracksPath = rotate == 'auto' || rotate == 'auto-reverse';
  final values = <AnimatableValue>[];
  for (var i = 0; i < _motionPathSamples; i += 1) {
    final MotionPathSample sample = path.sampleAtFraction(i / (_motionPathSamples - 1));
    final double angle = switch (rotate) {
      'auto' => sample.angleInDegrees,
      'auto-reverse' => sample.angleInDegrees + 180,
      _ => fixedRotation ?? 0,
    };
    values.add(
      TransformListValue(<TransformValue>[
        TransformValue('translate', <double>[sample.x, sample.y]),
        if (tracksPath || angle != 0) TransformValue('rotate', <double>[angle]),
      ]),
    );
  }

  return SvgAttributeAnimation(
    attributeName: 'transform',
    values: values,
    keyTimes: evenKeyTimes(values.length),
    timing: timing,
    // Motion moves the element within its parent's coordinate system, so it
    // composes outside of any transform the element already has.
    additive: true,
    prependsToUnderlyingValue: true,
    accumulate: accumulate,
  );
}

SvgAnimationTiming? _parseTiming(XmlElement element, {required bool isSet}) {
  Duration begin = Duration.zero;
  final String? rawBegin = attributeByLocalName(element, 'begin');
  if (rawBegin != null && rawBegin.trim().isNotEmpty) {
    Duration? parsed;
    for (final String token in rawBegin.split(';')) {
      parsed = parseClockValue(token);
      if (parsed != null) {
        break;
      }
    }
    if (parsed == null) {
      // The animation is triggered by an event or is explicitly indefinite, so
      // it never runs in a non-interactive rendering.
      return null;
    }
    begin = parsed;
  }

  final String? rawDuration = attributeByLocalName(element, 'dur');
  final Duration? simpleDuration = rawDuration == null ? null : parseClockValue(rawDuration);

  double? repeatCount;
  var repeatsIndefinitely = false;
  final String? rawRepeatCount = attributeByLocalName(element, 'repeatCount')?.trim();
  if (rawRepeatCount == 'indefinite') {
    repeatsIndefinitely = true;
  } else if (rawRepeatCount != null) {
    repeatCount = double.tryParse(rawRepeatCount);
  }
  final String? rawRepeatDuration = attributeByLocalName(element, 'repeatDur')?.trim();
  if (rawRepeatDuration == 'indefinite') {
    repeatsIndefinitely = true;
  } else if (rawRepeatDuration != null && simpleDuration != null) {
    final Duration? repeatDuration = parseClockValue(rawRepeatDuration);
    if (repeatDuration != null && simpleDuration > Duration.zero) {
      final double count = repeatDuration.inMicroseconds / simpleDuration.inMicroseconds;
      repeatCount = repeatCount == null ? count : math.min(repeatCount, count);
    }
  }

  final String? rawEnd = attributeByLocalName(element, 'end');
  final Duration? end = rawEnd == null ? null : parseClockValue(rawEnd);

  // `<set>` holds its value for its whole active duration, which is indefinite
  // unless the element says otherwise.
  final bool defaultsToIndefinite = isSet && rawDuration == null;

  return SvgAnimationTiming(
    begin: begin,
    simpleDuration: simpleDuration,
    repeatCount: repeatsIndefinitely && repeatCount == null
        ? null
        : repeatCount ?? (defaultsToIndefinite ? null : 1.0),
    end: end,
    fill: attributeByLocalName(element, 'fill')?.trim() == 'freeze'
        ? SvgFillMode.freeze
        : SvgFillMode.remove,
  );
}

SvgCalcMode _parseCalcMode(XmlElement element, {required SvgCalcMode defaultMode}) {
  switch (attributeByLocalName(element, 'calcMode')?.trim()) {
    case 'discrete':
      return SvgCalcMode.discrete;
    case 'linear':
      return SvgCalcMode.linear;
    case 'paced':
      return SvgCalcMode.paced;
    case 'spline':
      return SvgCalcMode.spline;
    default:
      return defaultMode;
  }
}

List<AnimatableValue>? _parseValues(
  XmlElement element,
  XmlElement target,
  String attributeName,
  String? transformType,
  String? Function(XmlElement element, String attributeName) baseValueOf, {
  required bool isSet,
}) {
  AnimatableValue? parse(String raw) =>
      parseAnimationValue(attributeName, raw, transformType: transformType);

  final String? to = attributeByLocalName(element, 'to');
  if (isSet) {
    if (to == null) {
      return null;
    }
    final AnimatableValue? value = parse(to);
    return value == null ? null : <AnimatableValue>[value];
  }

  final String? rawValues = attributeByLocalName(element, 'values');
  if (rawValues != null) {
    final values = <AnimatableValue>[];
    for (final String raw in rawValues.split(';')) {
      if (raw.trim().isEmpty) {
        continue;
      }
      final AnimatableValue? value = parse(raw);
      if (value == null) {
        return null;
      }
      values.add(value);
    }
    return values.isEmpty ? null : values;
  }

  final String? from = attributeByLocalName(element, 'from');
  final String? by = attributeByLocalName(element, 'by');
  AnimatableValue? start;
  if (from != null) {
    start = parse(from);
  } else {
    final String? base = baseValueOf(target, attributeName);
    start = base == null ? null : parse(base);
  }
  if (start == null) {
    return null;
  }
  if (to != null) {
    final AnimatableValue? end = parse(to);
    return end == null ? null : <AnimatableValue>[start, end];
  }
  if (by != null) {
    final AnimatableValue? offset = parse(by);
    final AnimatableValue? end = offset == null ? null : start.add(offset);
    return end == null ? null : <AnimatableValue>[start, end];
  }
  return null;
}

List<double>? _parseKeyTimes(XmlElement element, int expectedLength) {
  final String? raw = attributeByLocalName(element, 'keyTimes');
  if (raw == null) {
    return null;
  }
  final keyTimes = <double>[];
  for (final String token in raw.split(';')) {
    if (token.trim().isEmpty) {
      continue;
    }
    final double? value = double.tryParse(token.trim());
    if (value == null) {
      return null;
    }
    keyTimes.add(value);
  }
  if (keyTimes.length != expectedLength || keyTimes.first != 0) {
    return null;
  }
  for (var i = 1; i < keyTimes.length; i += 1) {
    if (keyTimes[i] < keyTimes[i - 1]) {
      return null;
    }
  }
  return keyTimes;
}

List<Curve>? _parseKeySplines(XmlElement element, int expectedLength) {
  final String? raw = attributeByLocalName(element, 'keySplines');
  if (raw == null || expectedLength <= 0) {
    return null;
  }
  final splines = <Curve>[];
  for (final String token in raw.split(';')) {
    if (token.trim().isEmpty) {
      continue;
    }
    final Curve? curve = parseKeySpline(token);
    if (curve == null) {
      return null;
    }
    splines.add(curve);
  }
  return splines.length == expectedLength ? splines : null;
}

/// Parses an animation value, taking `<animateTransform type="...">` into
/// account.
AnimatableValue? parseAnimationValue(String attributeName, String raw, {String? transformType}) {
  if (transformType != null) {
    final TransformValue? transform = TransformValue.parse(transformType, raw);
    return transform == null ? null : TransformListValue(<TransformValue>[transform]);
  }
  if (attributeName == 'transform') {
    return TransformListValue.parse(raw);
  }
  return parseAnimatableValue(attributeName, raw);
}
