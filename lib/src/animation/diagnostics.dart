import 'package:flutter/foundation.dart';
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

  /// A `<filter>` is used, and the renderer beneath this package drops filters.
  droppedFilter,

  /// The animation is long enough that it was sampled below the requested rate.
  reducedFrameRate,

  /// The compiled animation is large enough to be worth deciding about.
  expensive,
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

  final Set<String> filters = _usedFilters(document);
  if (filters.isNotEmpty) {
    final String opening =
        'This SVG uses ${filters.length} filter${filters.length == 1 ? '' : 's'}. '
        'vector_graphics, the renderer this package draws through, does not implement '
        '<filter>: the shapes are drawn and the blurs, glows and drop shadows are not.';
    final String? recipe = _blurRecipe(document, filters);
    diagnostics.add(
      SvgAnimateDiagnostic(
        SvgAnimateDiagnosticKind.droppedFilter,
        recipe == null ? '$opening Nothing in this package can add them.' : '$opening\n\n$recipe',
      ),
    );
  }

  return diagnostics;
}

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
