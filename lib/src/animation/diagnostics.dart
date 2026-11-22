import 'package:flutter/foundation.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart' as vg;
import 'package:xml/xml.dart';

/// What a diagnostic is about.
///
/// The kind is what code should branch on; [SvgAnimateDiagnostic.message] is
/// what a person should read.
enum SvgAnimateDiagnosticKind {
  /// The document declares no animation this package can find.
  noAnimation,

  /// The animation was sampled, and every sample drew the same picture.
  neverChanges,

  /// An `<image>` points somewhere the compiler will not follow.
  unreachableImage,

  /// A `<filter>` is used that the renderer beneath this package does not draw.
  ///
  /// Which filters those are depends on the version of `vector_graphics` an app
  /// resolves: from `vector_graphics_compiler` 1.3.6 on, filters made of
  /// `feGaussianBlur`, `feOffset` and `feMerge` are drawn and are not reported.
  droppedFilter,

  /// The animation is long enough that it was sampled below the requested rate.
  reducedFrameRate,

  /// The compiled animation is large enough to be worth deciding about.
  expensive,

  /// A `clip-path` is applied over text, which it will not reach.
  unclippedText,
}

/// Whether an [AnimatedSvgPicture] prints what an SVG asked for that will not
/// happen, the first time that SVG is compiled.
///
/// Debug builds only; nothing is printed in a release build whatever this says.
/// Set it to false for a test that deliberately loads an SVG with something
/// wrong in it, or for an app that would rather read
/// [AnimatedSvgFrames.diagnostics] itself.
bool svgAnimateReportDiagnostics = true;

/// Something about an SVG that this package, or the renderer beneath it, will
/// not do — reported rather than left to be deduced.
///
/// An animation that does not play looks the same whatever the reason: a still
/// picture and no error. These say which reason it was.
@immutable
class SvgAnimateDiagnostic {
  /// See class doc.
  const SvgAnimateDiagnostic(this.kind, this.message);

  /// What this is about.
  final SvgAnimateDiagnosticKind kind;

  /// A sentence or two explaining what will not happen, and why.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is SvgAnimateDiagnostic && other.kind == kind && other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => message;
}

/// What [document] contains that will not survive being compiled.
///
/// Runs over the document as it is once its animations have been resolved, so
/// the animation elements themselves are already gone and what is left is what
/// the compiler will actually be handed.
List<SvgAnimateDiagnostic> diagnoseDocument(XmlDocument document, {required bool hasAnimation}) {
  final diagnostics = <SvgAnimateDiagnostic>[];

  if (!hasAnimation) {
    diagnostics.add(
      SvgAnimateDiagnostic(
        SvgAnimateDiagnosticKind.noAnimation,
        _containsScript(document)
            ? 'This SVG declares no SMIL or CSS animation, and carries a <script> '
                  'element. Editors that export for their own JavaScript player put the '
                  'animation in that script and leave the markup holding the first frame, '
                  'which is all there is here to draw. Re-exporting as CSS or SMIL '
                  'animation puts the animation in the file itself.'
            : 'This SVG declares no SMIL or CSS animation, so there is a single frame '
                  'to draw and nothing to play.',
      ),
    );
  }

  for (final XmlElement image in document.descendantElements) {
    if (image.name.local != 'image') {
      continue;
    }
    final String? href = _href(image);
    if (href == null || href.startsWith('data:')) {
      continue;
    }
    diagnostics.add(
      SvgAnimateDiagnostic(
        SvgAnimateDiagnosticKind.unreachableImage,
        'An <image> points at "${_short(href)}". The compiler reads image data only '
        'from a data: URI and fetches nothing, so this image is left out of every '
        'frame without an error. Embed it in the SVG to have it drawn.',
      ),
    );
  }

  for (final XmlElement text in document.descendantElements) {
    if (text.name.local != 'text' || !_isClipped(text)) {
      continue;
    }
    diagnostics.add(
      const SvgAnimateDiagnostic(
        SvgAnimateDiagnosticKind.unclippedText,
        'A clip-path applies to a <text> element here. The clip does not reach the '
        'letters through this renderer: they are drawn in full whatever it says, so a '
        'wipe or a reveal over text stays fully drawn from the first frame to the last. '
        'Clipping shapes does work — the same effect over shapes, or the text converted '
        'to paths, both compile.',
      ),
    );
    break;
  }

  final SvgAnimateDiagnostic? filters = _droppedFilterDiagnostic(document);
  if (filters != null) {
    diagnostics.add(filters);
  }

  return diagnostics;
}

/// Reports the filters that the compiler in use leaves out, if any.
///
/// Whether a filter is drawn is asked of the compiler rather than looked up:
/// `vector_graphics_compiler` drew no filters at all before 1.3.6, draws blurs,
/// offsets and merges since, and an app resolves whichever its Flutter allows.
/// A list kept here would be wrong for one of them, which is how this message
/// came to tell people on a newer Flutter that a blur they could see was not
/// there.
SvgAnimateDiagnostic? _droppedFilterDiagnostic(XmlDocument document) {
  final Set<String> used = _usedFilters(document);
  if (used.isEmpty) {
    return null;
  }
  final Map<String, XmlElement> definitions = <String, XmlElement>{
    for (final XmlElement element in document.descendantElements)
      if (element.name.local == 'filter')
        if (element.getAttribute('id') case final String id) id: element,
  };
  // A reference to a filter that is not defined goes on being counted, as it
  // always has been.
  final Set<String> dropped = <String>{
    for (final String id in used)
      if (definitions[id] == null || !_compilerDraws(definitions[id]!)) id,
  };
  if (dropped.isEmpty) {
    return null;
  }

  final String count = '${dropped.length} filter${dropped.length == 1 ? '' : 's'}';
  final Set<String> primitives = <String>{
    for (final String id in dropped)
      if (definitions[id] case final XmlElement filter)
        for (final XmlElement primitive in filter.childElements) primitive.name.local,
  };

  if (_compilerDrawsPrimitive('feGaussianBlur')) {
    final String named = primitives.where((String p) => !_compilerDrawsPrimitive(p)).join(', ');
    return SvgAnimateDiagnostic(
      SvgAnimateDiagnosticKind.droppedFilter,
      'This SVG uses $count that the renderer leaves out: the shapes are drawn and '
      'the effect is not. vector_graphics leaves out the whole of a filter if it does '
      'not draw every primitive in it'
      '${named.isEmpty ? '' : ', and here it does not draw $named'}.',
    );
  }

  final String named = primitives
      .where((String p) => !_primitivesDrawnSince136.contains(p))
      .join(', ');
  final String upgrade = named.isEmpty
      ? 'vector_graphics_compiler 1.3.6 and later, which need Flutter 3.41, draw '
            'feGaussianBlur, feOffset and feMerge, which is everything '
            '${dropped.length == 1 ? 'this filter uses' : 'these filters use'}.'
      : 'vector_graphics_compiler 1.3.6 and later, which need Flutter 3.41, draw '
            'feGaussianBlur, feOffset and feMerge, but not $named, so '
            '${dropped.length == 1 ? 'this filter' : 'these filters'} would still be left out.';
  final String opening =
      'This SVG uses $count. The version of vector_graphics this app resolved draws '
      'no filters: the shapes are drawn and the blurs, glows and drop shadows are not. '
      '$upgrade';
  final String? recipe = _blurRecipe(document, dropped);
  return SvgAnimateDiagnostic(
    SvgAnimateDiagnosticKind.droppedFilter,
    recipe == null ? opening : '$opening\n\n$recipe',
  );
}

/// The primitives `vector_graphics_compiler` 1.3.6 draws, for telling somebody
/// on an earlier one what upgrading would get them.
///
/// Never used to decide whether a filter is drawn; see [_compilerDraws].
const Set<String> _primitivesDrawnSince136 = <String>{'feGaussianBlur', 'feOffset', 'feMerge'};

/// Whether the compiler in use draws [filter].
///
/// The compiler draws a filter when it draws every primitive in it and leaves
/// the whole filter out otherwise, so this asks the same question of it one
/// primitive at a time. Asking about the filter itself would be wrong whenever
/// its values do nothing in the document as written: a blur whose
/// `stdDeviation` is animated up from zero compiles, at zero, to the same bytes
/// as no blur at all.
bool _compilerDraws(XmlElement filter) {
  final List<XmlElement> primitives = filter.childElements.toList();
  return primitives.isNotEmpty &&
      primitives.every((XmlElement primitive) => _compilerDrawsPrimitive(primitive.name.local));
}

/// Whether the compiler in use draws the filter primitive called [name].
///
/// Compiles a square with a filter made of that primitive alone, with values
/// that visibly change the square, and once more without the filter. A
/// compiler that leaves the filter out produces the same bytes both ways. Two
/// encodes of a sixteen-pixel picture, once for each kind of primitive.
bool _compilerDrawsPrimitive(String name) {
  final bool Function(String primitive)? override = debugCompilerDrawsPrimitive;
  if (override != null) {
    return override(name);
  }
  return _probes.putIfAbsent(name, () => _probe(_probeMarkup[name] ?? '<$name/>'));
}

final Map<String, bool> _probes = <String, bool>{};

/// A primitive of each kind with values that make a difference. A kind not
/// listed is tried bare, which can only make it look undrawn when it is not —
/// the direction to err in for a diagnostic.
const Map<String, String> _probeMarkup = <String, String>{
  'feGaussianBlur': '<feGaussianBlur stdDeviation="2"/>',
  'feOffset': '<feOffset dx="2" dy="2"/>',
  'feMerge': '<feMerge><feMergeNode in="SourceAlpha"/><feMergeNode in="SourceGraphic"/></feMerge>',
  'feFlood': '<feFlood flood-color="#f00"/>',
  'feColorMatrix': '<feColorMatrix type="saturate" values="0"/>',
  'feComposite': '<feComposite in="SourceAlpha" in2="SourceGraphic" operator="xor"/>',
  'feBlend': '<feBlend in="SourceAlpha" in2="SourceGraphic" mode="multiply"/>',
  'feDropShadow': '<feDropShadow dx="2" dy="2" stdDeviation="2"/>',
  'feMorphology': '<feMorphology operator="dilate" radius="2"/>',
};

bool _probe(String primitive) {
  Uint8List encode(String attributes) => vg.encodeSvg(
    xml:
        '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">'
        '<defs><filter id="p">$primitive</filter></defs>'
        '<rect x="4" y="4" width="8" height="8" fill="#00f"$attributes/></svg>',
    debugName: 'Filter probe',
    enableClippingOptimizer: false,
    enableMaskingOptimizer: false,
    enableOverdrawOptimizer: false,
  );
  try {
    return !listEquals(encode(' filter="url(#p)"'), encode(''));
  } on Object {
    // A primitive the compiler cannot read alone, it does not draw either.
    return false;
  }
}

/// Replaces asking the compiler whether it draws a kind of filter primitive,
/// for tests that need to see what is reported under a compiler other than the
/// one resolved.
@visibleForTesting
bool Function(String primitive)? debugCompilerDrawsPrimitive;

/// Whether [element] or anything it sits inside asks to be clipped.
bool _isClipped(XmlElement element) {
  for (XmlNode? node = element; node != null; node = node.parent) {
    if (node is! XmlElement) {
      continue;
    }
    if (node.getAttribute('clip-path') != null) {
      return true;
    }
    final String? style = node.getAttribute('style');
    if (style != null && _clipDeclaration.hasMatch(style)) {
      return true;
    }
  }
  return false;
}

final RegExp _clipDeclaration = RegExp(r'(?:^|;)\s*clip-path\s*:', caseSensitive: false);

bool _containsScript(XmlDocument document) =>
    document.descendantElements.any((XmlElement e) => e.name.local == 'script');

/// The ids of filters that are actually reached, rather than every `<filter>`
/// defined, since a definition nothing refers to costs nothing.
Set<String> _usedFilters(XmlDocument document) {
  final used = <String>{};
  for (final XmlElement element in document.descendantElements) {
    final String? attribute = element.getAttribute('filter');
    if (attribute != null) {
      _collectReferences(attribute, used);
    }
    final String? style = element.getAttribute('style');
    if (style != null) {
      // Only the filter declaration: a style carries `fill: url(#gradient)`
      // far more often than it carries a filter, and a gradient is drawn.
      for (final RegExpMatch match in _filterDeclaration.allMatches(style)) {
        _collectReferences(match.group(1)!, used);
      }
    }
  }
  return used;
}

/// What to do instead, when the whole of what is being dropped is one blur.
///
/// The renderer cannot blur one element inside a picture, but Flutter can blur
/// the picture, and [AnimatedSvgPicture] already has the hook for it. That
/// covers the common case by a wide margin: a lone `feGaussianBlur` is what a
/// glow or a soft shadow is exported as.
///
/// Returns null for anything else — several filters, or a filter that does more
/// than blur — rather than describing a substitution that would not look like
/// what was asked for. Being told there is no way is better than being sent
/// after one that does not work.
String? _blurRecipe(XmlDocument document, Set<String> used) {
  if (used.length != 1) {
    return null;
  }
  final String id = used.single;
  XmlElement? filter;
  for (final XmlElement element in document.descendantElements) {
    if (element.name.local == 'filter' && element.getAttribute('id') == id) {
      filter = element;
      break;
    }
  }
  if (filter == null) {
    return null;
  }

  final List<XmlElement> primitives = filter.childElements.toList();
  if (primitives.length != 1 || primitives.single.name.local != 'feGaussianBlur') {
    return null;
  }

  final List<double> deviation = _numbers(primitives.single.getAttribute('stdDeviation'));
  if (deviation.isEmpty || deviation.first <= 0) {
    return null;
  }
  // One number means both axes, which is how `stdDeviation` is defined.
  final String x = _trim(deviation.first);
  final String y = _trim(deviation.length > 1 ? deviation[1] : deviation.first);

  return 'The whole of it is one feGaussianBlur, which Flutter can approximate at the '
      'widget layer even though the renderer cannot do it inside the picture:\n\n'
      '  AnimatedSvgPicture.asset(\n'
      '    ...,\n'
      '    imageBuilder: (BuildContext context, Widget child) => ImageFiltered(\n'
      '      imageFilter: ImageFilter.blur(sigmaX: $x, sigmaY: $y),\n'
      '      child: child,\n'
      '    ),\n'
      '  );\n\n'
      'That blurs everything the SVG draws rather than the one element the filter is '
      'on, and the sigma is in the SVG\'s own units, so it wants scaling by however '
      'much the picture is drawn larger or smaller than its view box.';
}

/// The numbers in an SVG list, which may be separated by commas, whitespace, or
/// both.
List<double> _numbers(String? value) {
  if (value == null) {
    return const <double>[];
  }
  return <double>[
    for (final RegExpMatch match in _number.allMatches(value))
      if (double.tryParse(match.group(0)!) case final double parsed) parsed,
  ];
}

final RegExp _number = RegExp(r'-?\d*\.?\d+(?:[eE][-+]?\d+)?');

/// Writes a double the way somebody would type it into Dart.
String _trim(double value) => value == value.roundToDouble() ? value.toStringAsFixed(1) : '$value';

void _collectReferences(String value, Set<String> into) {
  for (final RegExpMatch match in _urlReference.allMatches(value)) {
    into.add(match.group(1)!);
  }
}

final RegExp _urlReference = RegExp(r'url\(\s*#([^)\s]+)\s*\)');
final RegExp _filterDeclaration = RegExp(r'(?:^|;)\s*filter\s*:\s*([^;]+)', caseSensitive: false);

String? _href(XmlElement element) {
  for (final XmlAttribute attribute in element.attributes) {
    if (attribute.name.local == 'href') {
      return attribute.value;
    }
  }
  return null;
}

String _short(String value) => value.length <= 60 ? value : '${value.substring(0, 57)}...';
