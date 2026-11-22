import 'package:flutter/foundation.dart';

import 'values.dart';

/// One command of a path, in absolute coordinates.
@immutable
class _Segment {
  const _Segment(this.command, this.arguments);

  /// The upper case command letter.
  final String command;
  final List<double> arguments;
}

/// How many numbers each command takes.
const Map<String, int> _argumentCounts = <String, int>{
  'M': 2,
  'L': 2,
  'H': 1,
  'V': 1,
  'C': 6,
  'S': 4,
  'Q': 4,
  'T': 2,
  'A': 7,
  'Z': 0,
};

/// Path data, as the value of an animated `d`.
///
/// SVG 2 interpolates two paths when they have the same commands in the same
/// order, whether each is written absolute or relative: the numbers blend one
/// for one, and an arc's two flags switch halfway. That is what Chrome draws,
/// and what icon sets rely on to grow a bar or open a shape. Paths whose
/// commands differ cannot blend, and switch from one to the other halfway
/// through, as any value that cannot be interpolated does.
///
/// Both sides are read into absolute coordinates, so a relative command blends
/// with its absolute twin. Interpolating the absolute numbers is the same as
/// interpolating the relative ones, since one is a running sum of the other.
@immutable
class PathDataValue extends AnimatableValue {
  const PathDataValue._(this._segments);

  /// Reads [raw], or returns null if it is not path data this can read.
  ///
  /// Accepts the CSS form `path("...")` as well as plain path data.
  static PathDataValue? parse(String raw) {
    var text = raw.trim();
    final RegExpMatch? wrapped = RegExp(
      r'''^path\(\s*(["'])(.*)\1\s*\)$''',
      dotAll: true,
    ).firstMatch(text);
    if (wrapped != null) {
      text = wrapped.group(2)!;
    }
    final List<_Segment>? segments = _PathReader(text).read();
    return segments == null || segments.isEmpty ? null : PathDataValue._(segments);
  }

  final List<_Segment> _segments;

  bool _matches(PathDataValue other) {
    if (other._segments.length != _segments.length) {
      return false;
    }
    for (var i = 0; i < _segments.length; i += 1) {
      if (_segments[i].command != other._segments[i].command) {
        return false;
      }
    }
    return true;
  }

  @override
  AnimatableValue? lerp(AnimatableValue other, double t) {
    if (other is! PathDataValue || !_matches(other)) {
      return null;
    }
    return PathDataValue._(<_Segment>[
      for (var i = 0; i < _segments.length; i += 1)
        _Segment(_segments[i].command, <double>[
          for (var j = 0; j < _segments[i].arguments.length; j += 1)
            _blend(_segments[i], other._segments[i], j, t),
        ]),
    ]);
  }

  static double _blend(_Segment from, _Segment to, int index, double t) {
    final double a = from.arguments[index];
    final double b = to.arguments[index];
    if (from.command == 'A' && index >= 3 && index <= 4) {
      // The large arc and sweep flags are either set or not.
      return t < 0.5 ? a : b;
    }
    return a + (b - a) * t;
  }

  @override
  AnimatableValue? add(AnimatableValue other) => null;

  @override
  double? distanceTo(AnimatableValue other) => null;

  @override
  String toAttributeValue() {
    final buffer = StringBuffer();
    for (final _Segment segment in _segments) {
      if (buffer.isNotEmpty) {
        buffer.write(' ');
      }
      buffer.write(segment.command);
      for (var i = 0; i < segment.arguments.length; i += 1) {
        buffer.write(i == 0 ? '' : ' ');
        buffer.write(formatSvgNumber(segment.arguments[i]));
      }
    }
    return buffer.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is PathDataValue && other.toAttributeValue() == toAttributeValue();

  @override
  int get hashCode => toAttributeValue().hashCode;

  @override
  String toString() => 'PathDataValue(${toAttributeValue()})';
}

/// Reads path data into absolute segments, following the SVG path grammar:
/// numbers may run together (`1.5.5`, `1-2`), a command letter may be left out
/// to repeat the last one, and the numbers after a move are line segments.
class _PathReader {
  _PathReader(this._text);

  final String _text;
  int _position = 0;

  static final RegExp _number = RegExp(r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?');

  List<_Segment>? read() {
    final segments = <_Segment>[];
    var x = 0.0;
    var y = 0.0;
    var startX = 0.0;
    var startY = 0.0;
    String? command;
    while (true) {
      _skipSeparators();
      if (_position >= _text.length) {
        return segments;
      }
      final String next = _text[_position];
      if (RegExp('[MmLlHhVvCcSsQqTtAaZz]').hasMatch(next)) {
        command = next;
        _position += 1;
      } else if (command == null || command == 'Z' || command == 'z') {
        return null;
      }
      final String upper = command.toUpperCase();
      final bool relative = command != upper;
      final int count = _argumentCounts[upper]!;
      final numbers = <double>[];
      for (var i = 0; i < count; i += 1) {
        final bool flag = upper == 'A' && (i == 3 || i == 4);
        final double? value = flag ? _flag() : _readNumber();
        if (value == null) {
          return null;
        }
        numbers.add(value);
      }
      switch (upper) {
        case 'M':
        case 'L':
        case 'T':
          if (relative) {
            numbers[0] += x;
            numbers[1] += y;
          }
          x = numbers[0];
          y = numbers[1];
          if (upper == 'M') {
            startX = x;
            startY = y;
          }
        case 'H':
          if (relative) {
            numbers[0] += x;
          }
          x = numbers[0];
        case 'V':
          if (relative) {
            numbers[0] += y;
          }
          y = numbers[0];
        case 'C':
        case 'S':
        case 'Q':
          if (relative) {
            for (var i = 0; i < numbers.length; i += 2) {
              numbers[i] += x;
              numbers[i + 1] += y;
            }
          }
          x = numbers[numbers.length - 2];
          y = numbers[numbers.length - 1];
        case 'A':
          if (relative) {
            numbers[5] += x;
            numbers[6] += y;
          }
          x = numbers[5];
          y = numbers[6];
        case 'Z':
          x = startX;
          y = startY;
      }
      segments.add(_Segment(upper, numbers));
      // Numbers that follow a move without a new letter are lines.
      if (upper == 'M') {
        command = relative ? 'l' : 'L';
      }
    }
  }

  void _skipSeparators() {
    while (_position < _text.length) {
      final int unit = _text.codeUnitAt(_position);
      if (unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0C) {
        _position += 1;
      } else {
        return;
      }
    }
  }

  void _skipComma() {
    _skipSeparators();
    if (_position < _text.length && _text[_position] == ',') {
      _position += 1;
    }
  }

  double? _readNumber() {
    _skipSeparators();
    final Match? match = _number.matchAsPrefix(_text, _position);
    if (match == null) {
      return null;
    }
    _position = match.end;
    _skipComma();
    return double.tryParse(match.group(0)!);
  }

  /// An arc flag, which is one character and may run straight into the next
  /// number: `a1 1 0 0110 10` has the flags 0 and 1 and the point 10, 10.
  double? _flag() {
    _skipSeparators();
    if (_position >= _text.length) {
      return null;
    }
    final String character = _text[_position];
    if (character != '0' && character != '1') {
      return null;
    }
    _position += 1;
    _skipComma();
    return character == '1' ? 1 : 0;
  }
}
