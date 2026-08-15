import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '_named_colors.dart';

/// The attributes whose values are parsed as colors rather than as numbers.
///
/// See https://www.w3.org/TR/SVG11/propidx.html.
const Set<String> _colorAttributes = <String>{
  'color',
  'fill',
  'flood-color',
  'lighting-color',
  'solid-color',
  'stop-color',
  'stroke',
};

final RegExp _numberPattern = RegExp(r'^([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)([a-zA-Z%]*)$');

final RegExp _listSeparator = RegExp(r'[\s,]+');

final RegExp _transformFunctionPattern = RegExp(r'([a-zA-Z]+)\s*\(([^)]*)\)');

/// Formats [value] the way an SVG attribute would normally spell it, without a
/// trailing `.0` and without exponent notation.
String formatSvgNumber(double value) {
  if (!value.isFinite) {
    return '0';
  }
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toInt().toString();
  }
  final String text = value.toStringAsFixed(6);
  int end = text.length;
  while (end > 0 && text[end - 1] == '0') {
    end -= 1;
  }
  if (end > 0 && text[end - 1] == '.') {
    end -= 1;
  }
  return text.substring(0, end);
}

/// A parsed SVG attribute value that an animation can interpolate.
///
/// Values are immutable so that they can be shared between the frames of an
/// animation and cached alongside them.
@immutable
abstract class AnimatableValue {
  /// Allows const constructors on subclasses.
  const AnimatableValue();

  /// Serializes this value back into the string form of an SVG attribute.
  String toAttributeValue();

  /// Interpolates from this value towards [other] at [t], which is normally in
  /// the range 0.0 to 1.0.
  ///
  /// Returns null if [other] is not compatible with this value, in which case
  /// the caller falls back to discrete (non-interpolated) behavior.
  AnimatableValue? lerp(AnimatableValue other, double t);

  /// Adds [other] to this value component by component, as required by `by`
  /// animations and by `accumulate="sum"`.
  ///
  /// Returns null if the values cannot be added.
  AnimatableValue? add(AnimatableValue other);

  /// Layers this value on top of [other], as required by `additive="sum"`.
  ///
  /// This is component-wise addition for most values, but transform lists
  /// compose by concatenation rather than by summing their arguments.
  AnimatableValue? compose(AnimatableValue other) => add(other);

  /// The scalar magnitude of the difference between this value and [other],
  /// used to distribute time evenly for `calcMode="paced"`.
  ///
  /// Returns null if no meaningful distance exists.
  double? distanceTo(AnimatableValue other);
}

/// A value made up of one or more numbers that all share a unit, such as
/// `10`, `50%`, `1.5em`, or the four numbers of a `viewBox`.
class NumberListValue extends AnimatableValue {
  /// Creates a value from already parsed [numbers] and an optional [unit].
  const NumberListValue(this.numbers, {this.unit = ''});

  /// Parses a whitespace or comma separated list of numbers.
  ///
  /// Returns null if any component is not a number, or if the components do not
  /// all use the same unit.
  static NumberListValue? parse(String raw) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final numbers = <double>[];
    String? unit;
    for (final String token in trimmed.split(_listSeparator)) {
      if (token.isEmpty) {
        continue;
      }
      final RegExpMatch? match = _numberPattern.firstMatch(token);
      if (match == null) {
        return null;
      }
      final double? number = double.tryParse(match.group(1)!);
      if (number == null) {
        return null;
      }
      final String tokenUnit = match.group(2)!;
      if (unit == null) {
        unit = tokenUnit;
      } else if (unit != tokenUnit) {
        return null;
      }
      numbers.add(number);
    }
    if (numbers.isEmpty) {
      return null;
    }
    return NumberListValue(numbers, unit: unit!);
  }

  /// The parsed numbers, in source order.
  final List<double> numbers;

  /// The unit shared by every entry of [numbers], e.g. `px`, `%`, or the empty
  /// string for unitless values.
  final String unit;

  @override
  String toAttributeValue() =>
      numbers.map((double number) => '${formatSvgNumber(number)}$unit').join(' ');

  @override
  AnimatableValue? lerp(AnimatableValue other, double t) {
    if (other is! NumberListValue || other.numbers.length != numbers.length || other.unit != unit) {
      return null;
    }
    return NumberListValue(<double>[
      for (var i = 0; i < numbers.length; i += 1) numbers[i] + (other.numbers[i] - numbers[i]) * t,
    ], unit: unit);
  }

  @override
  AnimatableValue? add(AnimatableValue other) {
    if (other is! NumberListValue || other.numbers.length != numbers.length || other.unit != unit) {
      return null;
    }
    return NumberListValue(<double>[
      for (var i = 0; i < numbers.length; i += 1) numbers[i] + other.numbers[i],
    ], unit: unit);
  }

  @override
  double? distanceTo(AnimatableValue other) {
    if (other is! NumberListValue || other.numbers.length != numbers.length || other.unit != unit) {
      return null;
    }
    var sum = 0.0;
    for (var i = 0; i < numbers.length; i += 1) {
      final double delta = other.numbers[i] - numbers[i];
      sum += delta * delta;
    }
    return math.sqrt(sum);
  }

  @override
  bool operator ==(Object other) =>
      other is NumberListValue && other.unit == unit && listEquals<double>(other.numbers, numbers);

  @override
  int get hashCode => Object.hash(unit, Object.hashAll(numbers));

  @override
  String toString() => 'NumberListValue(${toAttributeValue()})';
}

/// A color value, stored as a packed 32 bit ARGB integer.
class ColorValue extends AnimatableValue {
  /// Creates a color from a packed 32 bit ARGB integer.
  const ColorValue(this.argb);

  /// Parses the SVG color syntaxes that can be interpolated: hex triples and
  /// quads, `rgb()`/`rgba()`, `hsl()`/`hsla()`, and the SVG color keywords.
  ///
  /// Returns null for anything else, including `none`, `currentColor`, and
  /// paint server references, which are not interpolable.
  static ColorValue? parse(String raw) {
    final String value = raw.trim();
    if (value.isEmpty) {
      return null;
    }
    if (value.startsWith('#')) {
      return _parseHex(value);
    }
    final String lowerCase = value.toLowerCase();
    if (lowerCase.startsWith('rgb')) {
      return _parseFunction(value, _rgbComponents);
    }
    if (lowerCase.startsWith('hsl')) {
      return _parseFunction(value, _hslComponents);
    }
    final int? named = namedColors[lowerCase];
    return named == null ? null : ColorValue(named);
  }

  static ColorValue? _parseHex(String value) {
    String digits = value.substring(1);
    if (digits.length == 3 || digits.length == 4) {
      digits = digits.split('').map((String digit) => '$digit$digit').join();
    }
    if (digits.length != 6 && digits.length != 8) {
      return null;
    }
    final int? rgb = int.tryParse(digits.substring(0, 6), radix: 16);
    if (rgb == null) {
      return null;
    }
    var alpha = 255;
    if (digits.length == 8) {
      final int? parsed = int.tryParse(digits.substring(6, 8), radix: 16);
      if (parsed == null) {
        return null;
      }
      alpha = parsed;
    }
    return ColorValue(rgb | alpha << 24);
  }

  static ColorValue? _parseFunction(String value, int? Function(List<String> arguments) toRgb) {
    final int start = value.indexOf('(');
    final int end = value.lastIndexOf(')');
    if (start == -1 || end < start) {
      return null;
    }
    final List<String> arguments = value
        .substring(start + 1, end)
        .split(_listSeparator)
        .where((String argument) => argument.isNotEmpty && argument != '/')
        .toList();
    if (arguments.length != 3 && arguments.length != 4) {
      return null;
    }
    final int? rgb = toRgb(arguments.sublist(0, 3));
    if (rgb == null) {
      return null;
    }
    final int alpha = arguments.length == 4 ? _parseAlpha(arguments[3]) : 255;
    return ColorValue(rgb & 0x00FFFFFF | alpha << 24);
  }

  static int? _rgbComponents(List<String> arguments) {
    var rgb = 0;
    for (final argument in arguments) {
      final double? component = _parsePercentOrNumber(argument, 255);
      if (component == null) {
        return null;
      }
      rgb = rgb << 8 | component.round().clamp(0, 255);
    }
    return rgb;
  }

  static int? _hslComponents(List<String> arguments) {
    final double? hue = _parsePercentOrNumber(arguments[0], 360);
    final double? saturation = _parsePercentOrNumber(arguments[1], 1);
    final double? lightness = _parsePercentOrNumber(arguments[2], 1);
    if (hue == null || saturation == null || lightness == null) {
      return null;
    }
    return _hslToRgb(hue % 360, saturation.clamp(0.0, 1.0), lightness.clamp(0.0, 1.0));
  }

  /// Parses either a `<percentage>` scaled to [fullScale] or a plain number.
  static double? _parsePercentOrNumber(String raw, num fullScale) {
    if (raw.endsWith('%')) {
      final double? percent = double.tryParse(raw.substring(0, raw.length - 1));
      return percent == null ? null : percent / 100 * fullScale;
    }
    return double.tryParse(raw);
  }

  static int _parseAlpha(String raw) {
    final double? alpha = _parsePercentOrNumber(raw, 1);
    if (alpha == null) {
      return 255;
    }
    return (alpha.clamp(0.0, 1.0) * 255).round();
  }

  static int _hslToRgb(double hue, double saturation, double lightness) {
    final double chroma = (1 - (2 * lightness - 1).abs()) * saturation;
    final double secondary = chroma * (1 - ((hue / 60) % 2 - 1).abs());
    final double match = lightness - chroma / 2;
    late double red;
    late double green;
    late double blue;
    if (hue < 60) {
      red = chroma;
      green = secondary;
      blue = 0;
    } else if (hue < 120) {
      red = secondary;
      green = chroma;
      blue = 0;
    } else if (hue < 180) {
      red = 0;
      green = chroma;
      blue = secondary;
    } else if (hue < 240) {
      red = 0;
      green = secondary;
      blue = chroma;
    } else if (hue < 300) {
      red = secondary;
      green = 0;
      blue = chroma;
    } else {
      red = chroma;
      green = 0;
      blue = secondary;
    }
    return ((red + match) * 255).round().clamp(0, 255) << 16 |
        ((green + match) * 255).round().clamp(0, 255) << 8 |
        ((blue + match) * 255).round().clamp(0, 255);
  }

  /// The packed 32 bit ARGB representation of this color.
  final int argb;

  /// The alpha channel, from 0 to 255.
  int get alpha => argb >> 24 & 0xFF;

  /// The red channel, from 0 to 255.
  int get red => argb >> 16 & 0xFF;

  /// The green channel, from 0 to 255.
  int get green => argb >> 8 & 0xFF;

  /// The blue channel, from 0 to 255.
  int get blue => argb & 0xFF;

  @override
  String toAttributeValue() {
    final String hex = (argb & 0x00FFFFFF).toRadixString(16).padLeft(6, '0');
    if (alpha == 255) {
      return '#$hex';
    }
    return '#$hex${alpha.toRadixString(16).padLeft(2, '0')}';
  }

  @override
  AnimatableValue? lerp(AnimatableValue other, double t) {
    if (other is! ColorValue) {
      return null;
    }
    int channel(int from, int to) => (from + (to - from) * t).round().clamp(0, 255);
    return ColorValue(
      channel(alpha, other.alpha) << 24 |
          channel(red, other.red) << 16 |
          channel(green, other.green) << 8 |
          channel(blue, other.blue),
    );
  }

  @override
  AnimatableValue? add(AnimatableValue other) {
    if (other is! ColorValue) {
      return null;
    }
    int channel(int a, int b) => (a + b).clamp(0, 255);
    return ColorValue(
      channel(alpha, other.alpha) << 24 |
          channel(red, other.red) << 16 |
          channel(green, other.green) << 8 |
          channel(blue, other.blue),
    );
  }

  @override
  double? distanceTo(AnimatableValue other) {
    if (other is! ColorValue) {
      return null;
    }
    final int deltaRed = other.red - red;
    final int deltaGreen = other.green - green;
    final int deltaBlue = other.blue - blue;
    return math.sqrt(
      (deltaRed * deltaRed + deltaGreen * deltaGreen + deltaBlue * deltaBlue).toDouble(),
    );
  }

  @override
  bool operator ==(Object other) => other is ColorValue && other.argb == argb;

  @override
  int get hashCode => argb.hashCode;

  @override
  String toString() => 'ColorValue(${toAttributeValue()})';
}

/// A single transform function, as produced by `<animateTransform>`.
class TransformValue extends AnimatableValue {
  /// Creates a transform of the given [type] with [parameters].
  const TransformValue(this.type, this.parameters);

  /// Creates a transform, dropping any arguments beyond what [type] takes.
  ///
  /// The SVG parser these values are handed to rejects an over-long argument
  /// list outright, so an SVG that writes one renders with the extra arguments
  /// ignored rather than failing altogether.
  factory TransformValue.truncated(String type, List<double> parameters) {
    final int limit = canonicalLength(type);
    return TransformValue(
      type,
      parameters.length <= limit ? parameters : parameters.sublist(0, limit),
    );
  }

  /// Parses the parameter list of an `<animateTransform>` value, such as
  /// `360 50 50` for `type="rotate"`.
  static TransformValue? parse(String type, String raw) {
    final NumberListValue? numbers = NumberListValue.parse(raw);
    if (numbers == null || numbers.unit.isNotEmpty) {
      return null;
    }
    return TransformValue.truncated(type, numbers.numbers);
  }

  /// The most arguments a transform of the given type accepts.
  static int canonicalLength(String type) {
    switch (type) {
      case 'translate':
      case 'scale':
        return 2;
      case 'rotate':
        return 3;
      case 'matrix':
        return 6;
      default:
        return 1;
    }
  }

  /// The transform function name, one of `translate`, `scale`, `rotate`,
  /// `skewX`, `skewY`, or `matrix`.
  final String type;

  /// The arguments to the transform function.
  final List<double> parameters;

  /// The same transform with arguments that leave everything where it was.
  TransformValue toIdentity() => TransformValue(
    type,
    // Scaling is the one that does nothing at one rather than at zero.
    List<double>.filled(parameters.length, type == 'scale' ? 1.0 : 0.0),
  );

  /// The parameter list padded out to [length] so that values written with
  /// different arities, such as `rotate(0)` and `rotate(360 50 50)`, can be
  /// combined.
  ///
  /// Callers pass the longer of the two lengths involved, so combining two
  /// equally short values does not spell out arguments that neither of them
  /// wrote, and a value carrying more arguments than its transform type calls
  /// for is padded rather than rejected.
  List<double> _paddedTo(int length) {
    if (parameters.length >= length) {
      return parameters;
    }
    return <double>[
      for (var i = 0; i < length; i += 1)
        if (i < parameters.length)
          parameters[i]
        // `scale(2)` is shorthand for `scale(2 2)`; every other transform
        // defaults its missing arguments to zero.
        else if (type == 'scale')
          parameters[0]
        else
          0.0,
    ];
  }

  @override
  String toAttributeValue() => '$type(${parameters.map(formatSvgNumber).join(' ')})';

  @override
  AnimatableValue? lerp(AnimatableValue other, double t) {
    if (other is! TransformValue || other.type != type) {
      return null;
    }
    final int length = math.max(parameters.length, other.parameters.length);
    final List<double> from = _paddedTo(length);
    final List<double> to = other._paddedTo(length);
    return TransformValue(type, <double>[
      for (var i = 0; i < from.length; i += 1) from[i] + (to[i] - from[i]) * t,
    ]);
  }

  @override
  AnimatableValue? add(AnimatableValue other) {
    if (other is! TransformValue || other.type != type) {
      return null;
    }
    final int length = math.max(parameters.length, other.parameters.length);
    final List<double> from = _paddedTo(length);
    final List<double> to = other._paddedTo(length);
    return TransformValue(type, <double>[
      for (var i = 0; i < from.length; i += 1)
        // Scaling is multiplicative, so summing two scale transforms composes
        // them rather than adding their factors.
        if (type == 'scale') from[i] * to[i] else from[i] + to[i],
    ]);
  }

  @override
  double? distanceTo(AnimatableValue other) {
    if (other is! TransformValue || other.type != type) {
      return null;
    }
    final int length = math.max(parameters.length, other.parameters.length);
    final List<double> from = _paddedTo(length);
    final List<double> to = other._paddedTo(length);
    var sum = 0.0;
    for (var i = 0; i < from.length; i += 1) {
      final double delta = to[i] - from[i];
      sum += delta * delta;
    }
    return math.sqrt(sum);
  }

  @override
  bool operator ==(Object other) =>
      other is TransformValue &&
      other.type == type &&
      listEquals<double>(other.parameters, parameters);

  @override
  int get hashCode => Object.hash(type, Object.hashAll(parameters));

  @override
  String toString() => 'TransformValue(${toAttributeValue()})';
}

/// An ordered list of transform functions, as written in an SVG `transform`
/// attribute or a CSS `transform` property.
class TransformListValue extends AnimatableValue {
  /// Creates a transform list from [transforms], which are applied in order.
  const TransformListValue(this.transforms);

  /// Parses a `transform` attribute or CSS `transform` property into the
  /// equivalent list of SVG transform functions.
  ///
  /// CSS spellings are normalized to their SVG equivalents: angles become
  /// degrees, lengths become user units, and axis specific functions such as
  /// `translateX` expand to their two argument forms. Returns null if any
  /// function cannot be expressed as an SVG transform, such as a `translate`
  /// with a percentage argument, which depends on the element's box.
  static TransformListValue? parse(String raw) {
    final String value = raw.trim();
    if (value.isEmpty || value == 'none') {
      return null;
    }
    final transforms = <TransformValue>[];
    var offset = 0;
    for (final RegExpMatch match in _transformFunctionPattern.allMatches(value)) {
      if (value.substring(offset, match.start).trim().isNotEmpty) {
        return null;
      }
      offset = match.end;
      final List<TransformValue>? parsed = _parseTransformFunction(
        match.group(1)!,
        match.group(2)!,
      );
      if (parsed == null) {
        return null;
      }
      transforms.addAll(parsed);
    }
    if (transforms.isEmpty || value.substring(offset).trim().isNotEmpty) {
      return null;
    }
    return TransformListValue(transforms);
  }

  static List<TransformValue>? _parseTransformFunction(String name, String rawArguments) {
    final arguments = <double>[];
    for (final String argument in rawArguments.split(_listSeparator)) {
      if (argument.isEmpty) {
        continue;
      }
      final double? parsed = _parseTransformArgument(name, argument);
      if (parsed == null) {
        return null;
      }
      arguments.add(parsed);
    }
    if (arguments.isEmpty) {
      return null;
    }
    switch (name) {
      case 'translate':
      case 'scale':
      case 'rotate':
      case 'skewX':
      case 'skewY':
      case 'matrix':
        return <TransformValue>[TransformValue.truncated(name, arguments)];
      case 'translateX':
        return <TransformValue>[
          TransformValue('translate', <double>[arguments[0], 0]),
        ];
      case 'translateY':
        return <TransformValue>[
          TransformValue('translate', <double>[0, arguments[0]]),
        ];
      case 'scaleX':
        return <TransformValue>[
          TransformValue('scale', <double>[arguments[0], 1]),
        ];
      case 'scaleY':
        return <TransformValue>[
          TransformValue('scale', <double>[1, arguments[0]]),
        ];
      case 'rotateZ':
        return <TransformValue>[TransformValue.truncated('rotate', arguments)];
      case 'skew':
        return <TransformValue>[
          TransformValue('skewX', <double>[arguments[0]]),
          if (arguments.length > 1) TransformValue('skewY', <double>[arguments[1]]),
        ];
      default:
        return null;
    }
  }

  static double? _parseTransformArgument(String name, String argument) {
    final RegExpMatch? match = _numberPattern.firstMatch(argument);
    if (match == null) {
      return null;
    }
    final double? number = double.tryParse(match.group(1)!);
    if (number == null) {
      return null;
    }
    switch (match.group(2)!) {
      case '':
      case 'px':
      case 'deg':
        return number;
      case 'rad':
        return number * 180 / math.pi;
      case 'grad':
        return number * 0.9;
      case 'turn':
        return number * 360;
      default:
        // Percentages and physical length units depend on context that is not
        // available here.
        return null;
    }
  }

  /// The transform functions, outermost first.
  final List<TransformValue> transforms;

  /// A list of the same shape that leaves everything where it was.
  ///
  /// Used as the value a `transform` animation starts from when the element has
  /// none of its own, which is what CSS means by the initial `none`. It has to
  /// keep the shape rather than being an empty list, or the two ends of the
  /// animation would no longer be interpolable.
  TransformListValue toIdentity() => TransformListValue(<TransformValue>[
    for (final TransformValue transform in transforms) transform.toIdentity(),
  ]);

  bool _matches(TransformListValue other) {
    if (other.transforms.length != transforms.length) {
      return false;
    }
    for (var i = 0; i < transforms.length; i += 1) {
      if (other.transforms[i].type != transforms[i].type) {
        return false;
      }
    }
    return true;
  }

  @override
  String toAttributeValue() =>
      transforms.map((TransformValue transform) => transform.toAttributeValue()).join(' ');

  @override
  AnimatableValue? lerp(AnimatableValue other, double t) {
    if (other is! TransformListValue || !_matches(other)) {
      return null;
    }
    return TransformListValue(<TransformValue>[
      for (var i = 0; i < transforms.length; i += 1)
        transforms[i].lerp(other.transforms[i], t)! as TransformValue,
    ]);
  }

  @override
  AnimatableValue? add(AnimatableValue other) {
    if (other is! TransformListValue || !_matches(other)) {
      return null;
    }
    return TransformListValue(<TransformValue>[
      for (var i = 0; i < transforms.length; i += 1)
        transforms[i].add(other.transforms[i])! as TransformValue,
    ]);
  }

  @override
  AnimatableValue? compose(AnimatableValue other) {
    // Two transforms compose by applying one after the other, which is
    // concatenation, not a component-wise sum.
    if (other is TransformListValue) {
      return TransformListValue(<TransformValue>[...transforms, ...other.transforms]);
    }
    return null;
  }

  @override
  double? distanceTo(AnimatableValue other) {
    if (other is! TransformListValue || !_matches(other)) {
      return null;
    }
    var sum = 0.0;
    for (var i = 0; i < transforms.length; i += 1) {
      final double distance = transforms[i].distanceTo(other.transforms[i])!;
      sum += distance * distance;
    }
    return math.sqrt(sum);
  }

  @override
  bool operator ==(Object other) =>
      other is TransformListValue && listEquals<TransformValue>(other.transforms, transforms);

  @override
  int get hashCode => Object.hashAll(transforms);

  @override
  String toString() => 'TransformListValue(${toAttributeValue()})';
}

/// A value that cannot be interpolated, such as `none`, `currentColor`, or a
/// `url(#gradient)` paint server reference.
///
/// Keyword values still animate, but only discretely: the value switches to the
/// next keyframe rather than blending into it.
class KeywordValue extends AnimatableValue {
  /// Creates a keyword value that renders as [text].
  const KeywordValue(this.text);

  /// The literal attribute text.
  final String text;

  @override
  String toAttributeValue() => text;

  @override
  AnimatableValue? lerp(AnimatableValue other, double t) => t < 1.0 ? this : other;

  @override
  AnimatableValue? add(AnimatableValue other) => null;

  @override
  double? distanceTo(AnimatableValue other) => null;

  @override
  bool operator ==(Object other) => other is KeywordValue && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'KeywordValue($text)';
}

/// Parses [raw] into the most specific [AnimatableValue] that fits, using
/// [attributeName] to decide whether a bare word should be read as a color.
///
/// This never fails; values that cannot be interpreted become a
/// [KeywordValue], which animates discretely.
AnimatableValue parseAnimatableValue(String attributeName, String raw) {
  final String value = raw.trim();
  if (_colorAttributes.contains(attributeName)) {
    final ColorValue? color = ColorValue.parse(value);
    if (color != null) {
      return color;
    }
  } else if (value.startsWith('#')) {
    final ColorValue? color = ColorValue.parse(value);
    if (color != null) {
      return color;
    }
  }
  return NumberListValue.parse(value) ?? KeywordValue(value);
}
