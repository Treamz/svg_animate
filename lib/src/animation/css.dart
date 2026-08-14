import 'package:xml/xml.dart';

/// A single `property: value` pair from a CSS declaration block.
class CssDeclaration {
  /// Creates a declaration.
  const CssDeclaration(this.value, {this.important = false});

  /// The declared value, with any `!important` flag removed.
  final String value;

  /// Whether the declaration was marked `!important`.
  final bool important;

  @override
  String toString() => important ? '$value !important' : value;
}

/// One part of a selector, such as `rect.big#hero`.
class _CompoundSelector {
  _CompoundSelector(this.tag, this.id, this.classes);

  final String? tag;
  final String? id;
  final List<String> classes;

  int get specificity =>
      (id == null ? 0 : 1 << 16) + classes.length * (1 << 8) + (tag == null ? 0 : 1);

  bool matches(XmlElement element) {
    if (tag != null && element.name.local != tag) {
      return false;
    }
    if (id != null && element.getAttribute('id') != id) {
      return false;
    }
    if (classes.isEmpty) {
      return true;
    }
    final List<String> elementClasses =
        element.getAttribute('class')?.split(RegExp(r'\s+')) ?? const <String>[];
    return classes.every(elementClasses.contains);
  }

  /// Parses a compound selector, returning null for anything using syntax this
  /// package does not support, such as pseudo-classes or attribute selectors.
  static _CompoundSelector? parse(String source) {
    if (source.isEmpty || source.contains(':') || source.contains('[')) {
      return null;
    }
    if (source == '*') {
      return _CompoundSelector(null, null, const <String>[]);
    }
    String? tag;
    String? id;
    final classes = <String>[];
    var index = 0;
    if (source[0] != '.' && source[0] != '#') {
      final int next = source.indexOf(RegExp(r'[.#]'));
      tag = next == -1 ? source : source.substring(0, next);
      index = tag.length;
    }
    while (index < source.length) {
      final String marker = source[index];
      final int next = source.indexOf(RegExp(r'[.#]'), index + 1);
      final String name = next == -1
          ? source.substring(index + 1)
          : source.substring(index + 1, next);
      if (name.isEmpty) {
        return null;
      }
      if (marker == '#') {
        id = name;
      } else {
        classes.add(name);
      }
      index = next == -1 ? source.length : next;
    }
    return _CompoundSelector(tag, id, classes);
  }
}

/// A CSS selector limited to type, class, id, and universal parts joined by
/// descendant or child combinators.
class CssSelector {
  CssSelector._(this._compounds, this._childCombinator);

  final List<_CompoundSelector> _compounds;

  /// Whether the combinator to the left of each compound is a child
  /// combinator. The first entry is unused.
  final List<bool> _childCombinator;

  /// The selector's specificity, used to order conflicting declarations.
  late final int specificity = _compounds.fold(
    0,
    (int total, _CompoundSelector compound) => total + compound.specificity,
  );

  /// Parses a single selector, returning null if it uses unsupported syntax.
  static CssSelector? parse(String source) {
    final String normalized = source.trim().replaceAll(RegExp(r'\s*>\s*'), '>');
    if (normalized.isEmpty) {
      return null;
    }
    final compounds = <_CompoundSelector>[];
    final childCombinator = <bool>[];
    for (final String descendant in normalized.split(RegExp(r'\s+'))) {
      final List<String> children = descendant.split('>');
      for (var i = 0; i < children.length; i += 1) {
        final _CompoundSelector? compound = _CompoundSelector.parse(children[i]);
        if (compound == null) {
          return null;
        }
        compounds.add(compound);
        childCombinator.add(i > 0);
      }
    }
    return compounds.isEmpty ? null : CssSelector._(compounds, childCombinator);
  }

  /// Whether [element] matches this selector.
  bool matches(XmlElement element) {
    if (!_compounds.last.matches(element)) {
      return false;
    }
    XmlNode? node = element.parent;
    for (int i = _compounds.length - 2; i >= 0; i -= 1) {
      final _CompoundSelector compound = _compounds[i];
      if (_childCombinator[i + 1]) {
        if (node is! XmlElement || !compound.matches(node)) {
          return false;
        }
        node = node.parent;
        continue;
      }
      var matched = false;
      while (node is XmlElement) {
        final XmlNode? parent = node.parent;
        if (compound.matches(node)) {
          matched = true;
          node = parent;
          break;
        }
        node = parent;
      }
      if (!matched) {
        return false;
      }
    }
    return true;
  }
}

/// A `selector { declarations }` rule.
class CssStyleRule {
  /// Creates a style rule.
  CssStyleRule(this.selectors, this.declarations, this.order);

  /// The selectors this rule applies to.
  final List<CssSelector> selectors;

  /// The declarations to apply, keyed by property name.
  final Map<String, CssDeclaration> declarations;

  /// The position of this rule in the stylesheet, used to break specificity
  /// ties.
  final int order;
}

/// One stop of a `@keyframes` rule.
class CssKeyframe {
  /// Creates a keyframe at the given [offsets], from 0.0 to 1.0.
  const CssKeyframe(this.offsets, this.declarations);

  /// The positions within the animation this keyframe applies to.
  final List<double> offsets;

  /// The declarations at this position.
  final Map<String, CssDeclaration> declarations;
}

/// A parsed `@keyframes` rule.
class CssKeyframes {
  /// Creates a keyframes rule named [name].
  const CssKeyframes(this.name, this.keyframes);

  /// The animation name this rule defines.
  final String name;

  /// The keyframes, in source order.
  final List<CssKeyframe> keyframes;
}

/// A stylesheet parsed from the contents of an SVG `<style>` element.
///
/// The supported subset covers what SVG files use in practice: type, class, id,
/// and universal selectors joined by descendant or child combinators, plain
/// declaration blocks, and `@keyframes` rules. At-rules other than
/// `@keyframes`, and selectors using pseudo-classes or attribute matching, are
/// skipped so that they cannot be applied incorrectly.
class CssStylesheet {
  /// Creates a stylesheet from already parsed [rules] and [keyframes].
  const CssStylesheet(this.rules, this.keyframes);

  /// An empty stylesheet.
  static const CssStylesheet empty = CssStylesheet(<CssStyleRule>[], <String, CssKeyframes>{});

  /// The style rules, in source order.
  final List<CssStyleRule> rules;

  /// The `@keyframes` rules, keyed by animation name.
  final Map<String, CssKeyframes> keyframes;

  /// Parses [source], the text content of one or more `<style>` elements.
  static CssStylesheet parse(String source) {
    final scanner = _CssScanner(_stripComments(source));
    final rules = <CssStyleRule>[];
    final keyframes = <String, CssKeyframes>{};
    var order = 0;
    while (!scanner.isDone) {
      scanner.skipWhitespace();
      if (scanner.isDone) {
        break;
      }
      if (scanner.peek() == '@') {
        final String prelude = scanner.readUntilBlockOrSemicolon();
        if (scanner.isDone || scanner.peek() != '{') {
          scanner.skipSemicolon();
          continue;
        }
        final String block = scanner.readBlock();
        final String atRule = prelude.trim();
        final int nameStart = atRule.indexOf(RegExp(r'\s'));
        final String atName = nameStart == -1
            ? atRule.substring(1)
            : atRule.substring(1, nameStart);
        if (atName == 'keyframes' || atName.endsWith('-keyframes')) {
          final String name = nameStart == -1 ? '' : atRule.substring(nameStart).trim();
          if (name.isNotEmpty) {
            keyframes[name] = CssKeyframes(name, _parseKeyframes(block));
          }
        }
        continue;
      }
      final String prelude = scanner.readUntilBlockOrSemicolon();
      if (scanner.isDone || scanner.peek() != '{') {
        scanner.skipSemicolon();
        continue;
      }
      final String block = scanner.readBlock();
      final selectors = <CssSelector>[];
      for (final String rawSelector in _splitTopLevel(prelude, ',')) {
        final CssSelector? selector = CssSelector.parse(rawSelector);
        if (selector != null) {
          selectors.add(selector);
        }
      }
      if (selectors.isNotEmpty) {
        rules.add(CssStyleRule(selectors, parseDeclarations(block), order));
        order += 1;
      }
    }
    return CssStylesheet(rules, keyframes);
  }

  static List<CssKeyframe> _parseKeyframes(String block) {
    final scanner = _CssScanner(block);
    final keyframes = <CssKeyframe>[];
    while (!scanner.isDone) {
      scanner.skipWhitespace();
      if (scanner.isDone) {
        break;
      }
      final String prelude = scanner.readUntilBlockOrSemicolon();
      if (scanner.isDone || scanner.peek() != '{') {
        scanner.skipSemicolon();
        continue;
      }
      final String body = scanner.readBlock();
      final offsets = <double>[];
      for (final String rawOffset in _splitTopLevel(prelude, ',')) {
        final double? offset = _parseKeyframeOffset(rawOffset.trim());
        if (offset != null) {
          offsets.add(offset);
        }
      }
      if (offsets.isNotEmpty) {
        keyframes.add(CssKeyframe(offsets, parseDeclarations(body)));
      }
    }
    return keyframes;
  }

  static double? _parseKeyframeOffset(String raw) {
    switch (raw.toLowerCase()) {
      case 'from':
        return 0.0;
      case 'to':
        return 1.0;
    }
    if (!raw.endsWith('%')) {
      return null;
    }
    final double? percent = double.tryParse(raw.substring(0, raw.length - 1));
    return percent == null ? null : percent / 100;
  }

  /// The declarations that apply to [element], ordered so that later entries
  /// win, and including the element's inline `style` attribute.
  Map<String, String> declarationsFor(XmlElement element) {
    final matched = <_MatchedDeclaration>[];
    for (final CssStyleRule rule in rules) {
      var bestSpecificity = -1;
      for (final CssSelector selector in rule.selectors) {
        if (selector.matches(element) && selector.specificity > bestSpecificity) {
          bestSpecificity = selector.specificity;
        }
      }
      if (bestSpecificity < 0) {
        continue;
      }
      for (final MapEntry<String, CssDeclaration> entry in rule.declarations.entries) {
        matched.add(_MatchedDeclaration(entry.key, entry.value, bestSpecificity, rule.order));
      }
    }
    // Inline styles beat every rule of the same importance.
    final String? inlineStyle = element.getAttribute('style');
    if (inlineStyle != null) {
      for (final MapEntry<String, CssDeclaration> entry in parseDeclarations(inlineStyle).entries) {
        matched.add(_MatchedDeclaration(entry.key, entry.value, 1 << 24, 1 << 24));
      }
    }
    matched.sort((_MatchedDeclaration a, _MatchedDeclaration b) {
      if (a.declaration.important != b.declaration.important) {
        return a.declaration.important ? 1 : -1;
      }
      if (a.specificity != b.specificity) {
        return a.specificity.compareTo(b.specificity);
      }
      return a.order.compareTo(b.order);
    });
    return <String, String>{
      for (final _MatchedDeclaration entry in matched) entry.property: entry.declaration.value,
    };
  }

  /// Parses a declaration block body such as `fill: red; opacity: .5`.
  static Map<String, CssDeclaration> parseDeclarations(String body) {
    final declarations = <String, CssDeclaration>{};
    for (final String part in _splitTopLevel(body, ';')) {
      final int separator = part.indexOf(':');
      if (separator <= 0) {
        continue;
      }
      final String property = part.substring(0, separator).trim().toLowerCase();
      String value = part.substring(separator + 1).trim();
      if (property.isEmpty || value.isEmpty) {
        continue;
      }
      var important = false;
      if (value.toLowerCase().endsWith('!important')) {
        important = true;
        value = value.substring(0, value.length - '!important'.length).trim();
      }
      declarations[property] = CssDeclaration(value, important: important);
    }
    return declarations;
  }
}

class _MatchedDeclaration {
  _MatchedDeclaration(this.property, this.declaration, this.specificity, this.order);

  final String property;
  final CssDeclaration declaration;
  final int specificity;
  final int order;
}

String _stripComments(String source) {
  final buffer = StringBuffer();
  var index = 0;
  while (index < source.length) {
    final int start = source.indexOf('/*', index);
    if (start == -1) {
      buffer.write(source.substring(index));
      break;
    }
    buffer.write(source.substring(index, start));
    final int end = source.indexOf('*/', start + 2);
    if (end == -1) {
      break;
    }
    index = end + 2;
  }
  return buffer.toString();
}

/// Splits [source] on [separator], ignoring separators nested in parentheses,
/// brackets, braces, or strings.
List<String> _splitTopLevel(String source, String separator) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var depth = 0;
  String? quote;
  for (var i = 0; i < source.length; i += 1) {
    final String character = source[i];
    if (quote != null) {
      buffer.write(character);
      if (character == quote) {
        quote = null;
      }
      continue;
    }
    switch (character) {
      case '"':
      case "'":
        quote = character;
      case '(':
      case '[':
      case '{':
        depth += 1;
      case ')':
      case ']':
      case '}':
        depth -= 1;
    }
    if (character == separator && depth <= 0) {
      parts.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(character);
  }
  if (buffer.isNotEmpty) {
    parts.add(buffer.toString());
  }
  return parts.where((String part) => part.trim().isNotEmpty).toList();
}

/// A minimal scanner over CSS source that understands balanced blocks.
class _CssScanner {
  _CssScanner(this._source);

  final String _source;
  int _index = 0;

  bool get isDone => _index >= _source.length;

  String peek() => _source[_index];

  void skipWhitespace() {
    while (!isDone && _source[_index].trim().isEmpty) {
      _index += 1;
    }
  }

  void skipSemicolon() {
    if (!isDone && _source[_index] == ';') {
      _index += 1;
    }
  }

  /// Reads up to, but not including, the next `{` or `;`.
  String readUntilBlockOrSemicolon() {
    final int start = _index;
    while (!isDone && _source[_index] != '{' && _source[_index] != ';') {
      _index += 1;
    }
    return _source.substring(start, _index);
  }

  /// Reads a balanced `{ ... }` block and returns its contents.
  String readBlock() {
    assert(_source[_index] == '{');
    _index += 1;
    final int start = _index;
    var depth = 1;
    String? quote;
    while (!isDone) {
      final String character = _source[_index];
      _index += 1;
      if (quote != null) {
        if (character == quote) {
          quote = null;
        }
        continue;
      }
      if (character == '"' || character == "'") {
        quote = character;
      } else if (character == '{') {
        depth += 1;
      } else if (character == '}') {
        depth -= 1;
        if (depth == 0) {
          return _source.substring(start, _index - 1);
        }
      }
    }
    return _source.substring(start);
  }
}
