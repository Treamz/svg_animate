import 'package:xml/xml.dart';

import 'animation.dart';

/// An [SvgAttributeAnimation] together with the element it animates.
///
/// Both the SMIL and the CSS parser produce these, so that the rest of the
/// pipeline does not need to know which syntax an animation came from.
class ParsedAnimation {
  /// Binds [animation] to [target].
  const ParsedAnimation(this.target, this.animation);

  /// The element whose attribute is animated.
  final XmlElement target;

  /// The animation to apply to [target].
  final SvgAttributeAnimation animation;
}
