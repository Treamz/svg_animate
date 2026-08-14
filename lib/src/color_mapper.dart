import 'package:flutter/widgets.dart' show Color;
import 'package:flutter_svg/flutter_svg.dart' show ColorMapper;
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart' as vg;

/// Adapts a [ColorMapper] so that the SVG compiler can call it.
///
/// Returns null for a null mapper, so callers can pass one straight through.
vg.ColorMapper? toVgColorMapper(ColorMapper? colorMapper) =>
    colorMapper == null ? null : _DelegatingColorMapper(colorMapper);

class _DelegatingColorMapper extends vg.ColorMapper {
  _DelegatingColorMapper(this.colorMapper);

  final ColorMapper colorMapper;

  @override
  vg.Color substitute(String? id, String elementName, String attributeName, vg.Color color) {
    final Color substitute = colorMapper.substitute(
      id,
      elementName,
      attributeName,
      Color(color.value),
    );
    return vg.Color(substitute.toARGB32());
  }
}
