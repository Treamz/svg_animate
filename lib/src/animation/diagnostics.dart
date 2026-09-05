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

  final int filters = _filterCount(document);
  if (filters > 0) {
    diagnostics.add(
      SvgAnimateDiagnostic(
        SvgAnimateDiagnosticKind.droppedFilter,
        'This SVG uses $filters filter${filters == 1 ? '' : 's'}. vector_graphics, the '
        'renderer this package draws through, does not implement <filter>: the shapes '
        'are drawn and the blurs, glows and drop shadows are not. Nothing in this '
        'package can add them.',
      ),
    );
  }

  return diagnostics;
}

bool _containsScript(XmlDocument document) =>
    document.descendantElements.any((XmlElement e) => e.name.local == 'script');

/// Counts filters that are actually reached, rather than every `<filter>`
/// defined, since a definition nothing refers to costs nothing.
int _filterCount(XmlDocument document) {
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
  return used.length;
}

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
