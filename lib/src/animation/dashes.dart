import 'dart:math' as math;

import 'package:vector_graphics_compiler/vector_graphics_compiler.dart' as vg;
import 'package:xml/xml.dart';

import 'values.dart' show formatSvgNumber;

/// The elements a stroke dash pattern is laid along.
const Set<String> _shapeNames = <String>{
  'path',
  'line',
  'polyline',
  'polygon',
  'rect',
  'circle',
  'ellipse',
};

/// The attributes that give a shape its geometry, which a copy of the shape
/// drawing only its stroke must not carry.
const Set<String> _geometryAttributes = <String>{
  'd',
  'x',
  'y',
  'width',
  'height',
  'rx',
  'ry',
  'cx',
  'cy',
  'r',
  'x1',
  'y1',
  'x2',
  'y2',
  'points',
  'pathLength',
  'id',
};

/// More dashes than this along one shape and it is left to the compiler.
///
/// A guard against a dash array of tiny values along a long path, which would
/// otherwise write tens of thousands of segments into every frame.
const int _maxIntervals = 20000;

/// A length short enough to be invisible at any size an SVG is drawn at.
///
/// Used where the compiler's dasher has to be given a dash it cannot be told to
/// skip; see [_dashSubpath].
const double _sliver = 1e-4;

/// Stroke dash patterns, laid out as geometry before the compiler sees them.
///
/// `vector_graphics_compiler` reads `stroke-dashoffset` and then never uses it,
/// so the usual way of drawing a path on — a dash as long as the path, slid
/// along it by animating the offset — compiled to a picture that never moved.
/// It ignores `pathLength` too. And it carries the dash pattern on from one
/// subpath to the next, where browsers start it again at the beginning of each
/// one, which icon sets that draw several strokes in one path rely on.
///
/// None of this needs the renderer to change. Every value is known when a frame
/// is sampled, so the dashes can be cut here, with the compiler's own dasher
/// ([vg.Path.dashed]) run once per subpath on a pattern already moved by the
/// offset, and the result written into the frame as plain path data the
/// compiler only has to stroke. Using its dasher rather than another one keeps
/// a dash's ends exactly where the compiler would have put them.
///
/// A dash array on its own is laid out here too. The compiler measures a curve
/// as its chord wherever the curve stays within 1.5 units of it, so dots along
/// an arc drift further from where browsers put them the further along the arc
/// they are, and the pattern runs on across subpaths there as well. line-md's
/// `downloading` and `uploading` spin a dotted half circle that way.
class DashedStrokes {
  DashedStrokes._(this._shapes);

  /// Finds the shapes in [document] whose dashes this has to lay out.
  ///
  /// [dashTargets] are the elements whose `stroke-dasharray` or
  /// `stroke-dashoffset` is animated, which may not have one in the markup.
  factory DashedStrokes.find(XmlDocument document, Set<XmlElement> dashTargets) {
    final shapes = <XmlElement>[];
    for (final XmlElement element in document.descendantElements) {
      if (!_shapeNames.contains(element.name.local)) {
        continue;
      }
      if (element.getAttribute('pathLength') != null || _hasDashesAbove(element, dashTargets)) {
        shapes.add(element);
      }
    }
    return DashedStrokes._(shapes);
  }

  final List<XmlElement> _shapes;

  /// Whether there is anything to lay out at all.
  bool get isEmpty => _shapes.isEmpty;

  final Map<String, vg.Path?> _parsedPaths = <String, vg.Path?>{};

  /// Rewrites every shape for the values the document holds now, and returns
  /// what puts the document back the way it was.
  ///
  /// The document is shared between frames and the animations write only the
  /// attributes they animate, so anything changed here has to be undone once
  /// the frame has been serialized, or the next frame would start from it.
  void Function() apply() {
    final edits = <_Edit>[];
    final added = <XmlElement>[];
    for (final XmlElement shape in _shapes) {
      _layOut(shape, edits, added);
    }
    return () {
      for (final XmlElement element in added) {
        element.remove();
      }
      for (final _Edit edit in edits.reversed) {
        edit.undo();
      }
    };
  }

  void _layOut(XmlElement shape, List<_Edit> edits, List<XmlElement> added) {
    final String? stroke = _inherited(shape, 'stroke');
    if (stroke == null || stroke == 'none') {
      return;
    }
    final List<double>? pattern = _dashArray(_inherited(shape, 'stroke-dasharray'));
    if (pattern == null) {
      return;
    }
    final double? offset = _length(_inherited(shape, 'stroke-dashoffset') ?? '0');
    if (offset == null) {
      return;
    }
    final vg.Path? geometry = _geometry(shape);
    if (geometry == null) {
      return;
    }
    final List<_Subpath> subpaths = _subpaths(geometry);

    var scale = 1.0;
    final String? rawPathLength = shape.getAttribute('pathLength');
    if (rawPathLength != null) {
      final double? pathLength = _length(rawPathLength);
      if (pathLength == null || pathLength <= 0) {
        // An invalid pathLength is ignored, the way browsers ignore it.
        scale = 1.0;
      } else {
        final double measured = subpaths.fold(0.0, (double sum, _Subpath s) => sum + s.length);
        scale = measured / pathLength;
      }
    }
    final List<double> scaled = <double>[for (final double value in pattern) value * scale];
    final double period = scaled.fold(0.0, (double sum, double value) => sum + value);
    if (period <= 0) {
      return;
    }

    final commands = <vg.PathCommand>[];
    var intervals = 0;
    var whole = subpaths.isNotEmpty;
    for (final _Subpath subpath in subpaths) {
      final List<vg.PathCommand>? dashed = _dashSubpath(subpath, scaled, period, offset * scale);
      if (dashed == null) {
        return;
      }
      whole = whole && identical(dashed, subpath.commands);
      intervals += dashed.length;
      if (intervals > _maxIntervals) {
        return;
      }
      commands.addAll(dashed);
    }

    if (whole) {
      // Every dash covers its whole subpath, which is the shape as authored:
      // the last frames of a path drawn on, and most of them in an icon set.
      // Leaving the geometry alone is cheaper for the compiler and the same
      // picture.
      _set(shape, 'stroke-dasharray', 'none', edits);
      return;
    }
    if (commands.isEmpty) {
      // The whole stroke falls in gaps. Saying so is simpler than writing a
      // path with nothing in it, and keeps whatever fill the shape has.
      _set(shape, 'stroke', 'none', edits);
      return;
    }
    final String data = _pathData(commands);
    final String? fill = _inherited(shape, 'fill');
    final bool unfilled = fill == 'none' || fill == 'transparent';
    if (shape.name.local == 'path' && unfilled) {
      _set(shape, 'd', data, edits);
      _set(shape, 'stroke-dasharray', 'none', edits);
      _remove(shape, 'stroke-dashoffset', edits);
      _remove(shape, 'pathLength', edits);
      return;
    }

    // The fill needs the shape's own outline and the stroke needs the dashes,
    // so the stroke moves to a copy drawn straight after it.
    final strokeOnly = XmlElement.tag('path');
    for (final XmlAttribute attribute in shape.attributes) {
      final String name = attribute.name.local;
      if (!_geometryAttributes.contains(name) &&
          name != 'fill' &&
          name != 'stroke-dasharray' &&
          name != 'stroke-dashoffset') {
        strokeOnly.setAttribute(attribute.name.qualified, attribute.value);
      }
    }
    strokeOnly
      ..setAttribute('d', data)
      ..setAttribute('fill', 'none')
      ..setAttribute('stroke-dasharray', 'none');
    final XmlNode parent = shape.parent!;
    parent.children.insert(parent.children.indexOf(shape) + 1, strokeOnly);
    added.add(strokeOnly);
    _set(shape, 'stroke', 'none', edits);
  }

  vg.Path? _geometry(XmlElement shape) {
    try {
      switch (shape.name.local) {
        case 'path':
          final String data = shape.getAttribute('d') ?? '';
          return _parsedPaths.putIfAbsent(data, () => vg.parseSvgPathData(data));
        case 'line':
          final double? x1 = _length(shape.getAttribute('x1') ?? '0');
          final double? y1 = _length(shape.getAttribute('y1') ?? '0');
          final double? x2 = _length(shape.getAttribute('x2') ?? '0');
          final double? y2 = _length(shape.getAttribute('y2') ?? '0');
          if (x1 == null || y1 == null || x2 == null || y2 == null) {
            return null;
          }
          return vg.Path(
            commands: <vg.PathCommand>[vg.MoveToCommand(x1, y1), vg.LineToCommand(x2, y2)],
          );
        case 'polyline':
        case 'polygon':
          return _polygon(
            shape.getAttribute('points') ?? '',
            closed: shape.name.local == 'polygon',
          );
        case 'rect':
          return _rect(shape);
        case 'circle':
          final double? r = _length(shape.getAttribute('r') ?? '0');
          return r == null ? null : _ellipse(shape, r, r);
        case 'ellipse':
          final double? rx = _length(shape.getAttribute('rx') ?? '0');
          final double? ry = _length(shape.getAttribute('ry') ?? '0');
          return rx == null || ry == null ? null : _ellipse(shape, rx, ry);
      }
    } on Object {
      // Path data the compiler's own parser rejects is left for the compiler
      // to report in its usual way.
      return null;
    }
    return null;
  }
}

/// One subpath of a shape, with its length as the compiler's dasher measures
/// it, and a length it can be relied on never to measure past.
class _Subpath {
  _Subpath(this.commands, this.length, this.bound);

  final List<vg.PathCommand> commands;
  final double length;
  final double bound;
}

List<_Subpath> _subpaths(vg.Path path) {
  final subpaths = <_Subpath>[];
  var commands = <vg.PathCommand>[];
  var current = vg.Point.zero;
  var start = current;
  var length = 0.0;
  var bound = 0.0;
  void finish() {
    if (commands.length > 1) {
      subpaths.add(_Subpath(commands, length, bound));
    }
    commands = <vg.PathCommand>[];
    length = 0;
    bound = 0;
  }

  for (final vg.PathCommand command in path.commands) {
    if (commands.isEmpty && command.type != vg.PathCommandType.move) {
      // Drawing without a move first starts from where the last subpath left
      // off, which is what the compiler does with it too.
      commands.add(vg.MoveToCommand(current.x, current.y));
    }
    switch (command.type) {
      case vg.PathCommandType.move:
        finish();
        final move = command as vg.MoveToCommand;
        current = vg.Point(move.x, move.y);
        start = current;
      case vg.PathCommandType.line:
        final line = command as vg.LineToCommand;
        final next = vg.Point(line.x, line.y);
        final double step = vg.Point.distance(current, next);
        length += step;
        bound += step;
        current = next;
      case vg.PathCommandType.cubic:
        for (final vg.CubicToCommand piece in _flatPieces(current, command as vg.CubicToCommand)) {
          length += piece.computeLength(current);
          // A cubic lies inside its control polygon, and the dasher measures
          // a piece of it as a chain of chords, so no measurement of it,
          // however it has been split, comes to more than the polygon.
          bound +=
              vg.Point.distance(current, piece.controlPoint1) +
              vg.Point.distance(piece.controlPoint1, piece.controlPoint2) +
              vg.Point.distance(piece.controlPoint2, piece.endPoint);
          commands.add(piece);
          current = piece.endPoint;
        }
        continue;
      case vg.PathCommandType.close:
        final double step = vg.Point.distance(current, start);
        length += step;
        bound += step;
        current = start;
    }
    commands.add(command);
    if (command.type == vg.PathCommandType.close) {
      // Anything drawn after a close is a new subpath from the same start.
      finish();
    }
  }
  finish();
  return subpaths;
}

/// How far a cubic may bow away from its chord before it is split.
const double _flatness = 0.1;

/// [cubic] split into pieces flat enough that the compiler's dasher measures
/// each one as it really is.
///
/// The dasher measures a curve as a chord wherever its control points are
/// within 1.5 units of it, which on a 24 unit icon is most curves: a circle
/// comes out a few percent short, and a path drawn on along it reaches its end
/// visibly early. Splitting with de Casteljau leaves the curve exactly as it
/// was and makes each chord a true measure of its piece.
Iterable<vg.CubicToCommand> _flatPieces(
  vg.Point start,
  vg.CubicToCommand cubic, [
  int depth = 0,
]) sync* {
  final double bow = math.max(
    vg.Point.distance(cubic.controlPoint1, vg.Point.lerp(start, cubic.endPoint, 1 / 3)),
    vg.Point.distance(cubic.controlPoint2, vg.Point.lerp(start, cubic.endPoint, 2 / 3)),
  );
  if (bow <= _flatness || depth >= 8) {
    yield cubic;
    return;
  }
  final List<vg.Point> halves = vg.CubicToCommand.subdivide(
    start,
    cubic.controlPoint1,
    cubic.controlPoint2,
    cubic.endPoint,
    0.5,
  );
  yield* _flatPieces(
    start,
    vg.CubicToCommand(halves[1].x, halves[1].y, halves[2].x, halves[2].y, halves[3].x, halves[3].y),
    depth + 1,
  );
  yield* _flatPieces(
    halves[3],
    vg.CubicToCommand(halves[4].x, halves[4].y, halves[5].x, halves[5].y, halves[6].x, halves[6].y),
    depth + 1,
  );
}

/// The dashes along one subpath, starting [offset] into [pattern], as the
/// commands that draw them, or null if there would be too many to write.
///
/// Every subpath starts the pattern again, as browsers do.
///
/// The compiler's dasher has no offset and always starts with a dash, so it is
/// given the pattern already rotated to where the offset puts the start. Where
/// that falls in a gap, it is given a sliver of a dash first, and the sliver is
/// cut out of what it returns.
List<vg.PathCommand>? _dashSubpath(
  _Subpath subpath,
  List<double> pattern,
  double period,
  double offset,
) {
  var position = offset % period;
  if (position < 0) {
    position += period;
  }
  var index = 0;
  // A zero length dash exactly where the subpath starts is still a dot there.
  while (position > pattern[index] || (position == pattern[index] && pattern[index] > 0)) {
    position -= pattern[index];
    index = (index + 1) % pattern.length;
  }
  final double remaining = pattern[index] - position;
  final bool inDash = index.isEven;

  if (inDash && remaining >= subpath.length) {
    return subpath.commands;
  }
  if (!inDash && remaining >= subpath.length) {
    return const <vg.PathCommand>[];
  }

  final intervals = <double>[];
  bool dropFirstDash;
  if (inDash) {
    // The compiler's dasher draws nothing at all from a first dash of zero.
    intervals.add(remaining > 0 ? remaining : _sliver);
    dropFirstDash = false;
  } else if (remaining > 2 * _sliver) {
    intervals
      ..add(_sliver)
      ..add(remaining - _sliver);
    dropFirstDash = true;
  } else {
    // Too little gap left to fit a sliver of dash in front of it. Starting at
    // the next dash instead moves the pattern by less than the sliver would.
    index = (index + 1) % pattern.length;
    intervals.add(pattern[index] > 0 ? pattern[index] : _sliver);
    dropFirstDash = false;
  }
  // Enough of the pattern to reach past the end of the subpath, so that the
  // dasher never wraps round to the start of a list that began part way in.
  var covered = intervals.fold(0.0, (double sum, double value) => sum + value);
  final double needed = subpath.bound + period;
  while (covered < needed) {
    index = (index + 1) % pattern.length;
    double value = pattern[index];
    if (value == 0 && index.isEven) {
      // A zero length dash is a dot where the line has a round or square cap.
      // The compiler's dasher skips one that lands on a corner, so it gets a
      // sliver instead.
      value = _sliver;
    }
    intervals.add(value);
    covered += value;
    if (intervals.length > _maxIntervals) {
      return null;
    }
  }

  final List<vg.PathCommand> dashed = vg.Path(
    commands: subpath.commands,
  ).dashed(intervals).commands.toList();
  if (!dropFirstDash) {
    return dashed;
  }
  // The sliver is everything between the first move and the second.
  final int next = dashed.indexWhere(
    (vg.PathCommand command) => command.type == vg.PathCommandType.move,
    1,
  );
  return next < 0 ? const <vg.PathCommand>[] : dashed.sublist(next);
}

String _pathData(List<vg.PathCommand> commands) {
  final buffer = StringBuffer();
  for (final vg.PathCommand command in commands) {
    switch (command.type) {
      case vg.PathCommandType.move:
        final move = command as vg.MoveToCommand;
        buffer.write('M${formatSvgNumber(move.x)} ${formatSvgNumber(move.y)}');
      case vg.PathCommandType.line:
        final line = command as vg.LineToCommand;
        buffer.write('L${formatSvgNumber(line.x)} ${formatSvgNumber(line.y)}');
      case vg.PathCommandType.cubic:
        final cubic = command as vg.CubicToCommand;
        buffer.write(
          'C${formatSvgNumber(cubic.x1)} ${formatSvgNumber(cubic.y1)} '
          '${formatSvgNumber(cubic.x2)} ${formatSvgNumber(cubic.y2)} '
          '${formatSvgNumber(cubic.x3)} ${formatSvgNumber(cubic.y3)}',
        );
      case vg.PathCommandType.close:
        buffer.write('Z');
    }
  }
  return buffer.toString();
}

/// The control point distance that makes a cubic follow a quarter circle.
const double _kappa = 0.5522847498307936;

/// An ellipse as SVG 2 lays it out for dashing: starting at its rightmost
/// point and going the way positive angles go, which is clockwise on screen.
vg.Path? _ellipse(XmlElement shape, double rx, double ry) {
  final double? cx = _length(shape.getAttribute('cx') ?? '0');
  final double? cy = _length(shape.getAttribute('cy') ?? '0');
  if (cx == null || cy == null || rx <= 0 || ry <= 0) {
    return null;
  }
  final double kx = rx * _kappa;
  final double ky = ry * _kappa;
  return vg.Path(
    commands: <vg.PathCommand>[
      vg.MoveToCommand(cx + rx, cy),
      vg.CubicToCommand(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry),
      vg.CubicToCommand(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy),
      vg.CubicToCommand(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry),
      vg.CubicToCommand(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy),
      const vg.CloseCommand(),
    ],
  );
}

/// A rect as SVG 2 lays it out for dashing: starting where the top edge's
/// straight part begins and going clockwise.
vg.Path? _rect(XmlElement shape) {
  final double? x = _length(shape.getAttribute('x') ?? '0');
  final double? y = _length(shape.getAttribute('y') ?? '0');
  final double? width = _length(shape.getAttribute('width') ?? '0');
  final double? height = _length(shape.getAttribute('height') ?? '0');
  final String? rawRx = shape.getAttribute('rx');
  final String? rawRy = shape.getAttribute('ry');
  final double? rx = rawRx == null ? null : _length(rawRx);
  final double? ry = rawRy == null ? null : _length(rawRy);
  if (x == null || y == null || width == null || height == null) {
    return null;
  }
  if ((rawRx != null && rx == null) || (rawRy != null && ry == null)) {
    return null;
  }
  if (width <= 0 || height <= 0) {
    return null;
  }
  var cornerX = rx ?? ry ?? 0;
  var cornerY = ry ?? rx ?? 0;
  if (cornerX < 0 || cornerY < 0) {
    cornerX = 0;
    cornerY = 0;
  }
  if (cornerX > width / 2) {
    cornerX = width / 2;
  }
  if (cornerY > height / 2) {
    cornerY = height / 2;
  }
  final double right = x + width;
  final double bottom = y + height;
  if (cornerX == 0 || cornerY == 0) {
    return vg.Path(
      commands: <vg.PathCommand>[
        vg.MoveToCommand(x, y),
        vg.LineToCommand(right, y),
        vg.LineToCommand(right, bottom),
        vg.LineToCommand(x, bottom),
        const vg.CloseCommand(),
      ],
    );
  }
  final double kx = cornerX * _kappa;
  final double ky = cornerY * _kappa;
  return vg.Path(
    commands: <vg.PathCommand>[
      vg.MoveToCommand(x + cornerX, y),
      vg.LineToCommand(right - cornerX, y),
      vg.CubicToCommand(right - cornerX + kx, y, right, y + cornerY - ky, right, y + cornerY),
      vg.LineToCommand(right, bottom - cornerY),
      vg.CubicToCommand(
        right,
        bottom - cornerY + ky,
        right - cornerX + kx,
        bottom,
        right - cornerX,
        bottom,
      ),
      vg.LineToCommand(x + cornerX, bottom),
      vg.CubicToCommand(x + cornerX - kx, bottom, x, bottom - cornerY + ky, x, bottom - cornerY),
      vg.LineToCommand(x, y + cornerY),
      vg.CubicToCommand(x, y + cornerY - ky, x + cornerX - kx, y, x + cornerX, y),
      const vg.CloseCommand(),
    ],
  );
}

vg.Path? _polygon(String raw, {required bool closed}) {
  final List<String> parts = raw.trim().split(RegExp(r'[\s,]+'));
  final numbers = <double>[];
  for (final String part in parts) {
    if (part.isEmpty) {
      continue;
    }
    final double? number = double.tryParse(part);
    if (number == null) {
      return null;
    }
    numbers.add(number);
  }
  if (numbers.length < 4) {
    return null;
  }
  return vg.Path(
    commands: <vg.PathCommand>[
      vg.MoveToCommand(numbers[0], numbers[1]),
      for (var i = 2; i + 1 < numbers.length; i += 2) vg.LineToCommand(numbers[i], numbers[i + 1]),
      if (closed) const vg.CloseCommand(),
    ],
  );
}

final RegExp _lengthPattern = RegExp(r'^([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)(px)?$');

/// A length in user units, or null for anything that needs more context to
/// resolve, such as a percentage.
double? _length(String raw) {
  final RegExpMatch? match = _lengthPattern.firstMatch(raw.trim());
  return match == null ? null : double.tryParse(match.group(1)!);
}

/// The dash pattern [raw] describes, doubled to an even length the way SVG
/// repeats an odd one, or null when it draws a solid line or cannot be read.
List<double>? _dashArray(String? raw) {
  if (raw == null || raw == 'none') {
    return null;
  }
  final values = <double>[];
  for (final String part in raw.split(RegExp(r'[\s,]+'))) {
    if (part.isEmpty) {
      continue;
    }
    final double? value = _length(part);
    if (value == null || value < 0) {
      return null;
    }
    values.add(value);
  }
  if (values.isEmpty || values.every((double value) => value == 0)) {
    return null;
  }
  return values.length.isOdd ? <double>[...values, ...values] : values;
}

/// The value of [name] that applies to [element], from itself or the nearest
/// element above it that sets it.
String? _inherited(XmlElement element, String name) {
  for (XmlNode? node = element; node is XmlElement; node = node.parent) {
    final String? value = node.getAttribute(name)?.trim();
    if (value != null && value != 'inherit') {
      return value;
    }
  }
  return null;
}

bool _hasDashesAbove(XmlElement element, Set<XmlElement> dashTargets) {
  for (XmlNode? node = element; node is XmlElement; node = node.parent) {
    if (dashTargets.contains(node) ||
        node.getAttribute('stroke-dasharray') != null ||
        node.getAttribute('stroke-dashoffset') != null) {
      return true;
    }
  }
  return false;
}

void _set(XmlElement element, String name, String value, List<_Edit> edits) {
  edits.add(_Edit(element, name, element.getAttribute(name)));
  element.setAttribute(name, value);
}

void _remove(XmlElement element, String name, List<_Edit> edits) {
  final String? previous = element.getAttribute(name);
  if (previous == null) {
    return;
  }
  edits.add(_Edit(element, name, previous));
  element.removeAttribute(name);
}

/// An attribute as it was before a frame was laid out.
class _Edit {
  _Edit(this.element, this.name, this.previous);

  final XmlElement element;
  final String name;
  final String? previous;

  void undo() {
    if (previous == null) {
      element.removeAttribute(name);
    } else {
      element.setAttribute(name, previous);
    }
  }
}
