import 'package:svg_animate/src/animation/values.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatSvgNumber', () {
    test('drops trailing zeros and decimal points', () {
      expect(formatSvgNumber(1), '1');
      expect(formatSvgNumber(1.5), '1.5');
      expect(formatSvgNumber(-0.25), '-0.25');
      expect(formatSvgNumber(360), '360');
    });

    test('never uses exponent notation', () {
      expect(formatSvgNumber(0.0000001), '0');
      expect(formatSvgNumber(1234567), '1234567');
    });
  });

  group('NumberListValue', () {
    test('parses single numbers, lists, and units', () {
      expect(NumberListValue.parse('42')!.numbers, <double>[42]);
      expect(NumberListValue.parse('0 0 24 24')!.numbers, <double>[0, 0, 24, 24]);
      expect(NumberListValue.parse('4, 2')!.numbers, <double>[4, 2]);
      expect(NumberListValue.parse('50%')!.unit, '%');
      expect(NumberListValue.parse('1.5em')!.unit, 'em');
      expect(NumberListValue.parse('-1e2')!.numbers, <double>[-100]);
    });

    test('rejects values that are not numbers or mix units', () {
      expect(NumberListValue.parse('none'), isNull);
      expect(NumberListValue.parse('10px 5%'), isNull);
      expect(NumberListValue.parse(''), isNull);
      expect(NumberListValue.parse('url(#a)'), isNull);
    });

    test('interpolates component-wise and keeps the unit', () {
      final AnimatableValue from = NumberListValue.parse('0 10')!;
      final AnimatableValue to = NumberListValue.parse('10 20')!;
      expect(from.lerp(to, 0.5)!.toAttributeValue(), '5 15');
      expect(
        NumberListValue.parse('0%')!.lerp(NumberListValue.parse('50%')!, 0.5)!.toAttributeValue(),
        '25%',
      );
    });

    test('does not interpolate between different shapes', () {
      expect(NumberListValue.parse('1')!.lerp(NumberListValue.parse('1 2')!, 0.5), isNull);
      expect(NumberListValue.parse('1px')!.lerp(NumberListValue.parse('2')!, 0.5), isNull);
    });

    test('adds and measures distance', () {
      expect(
        NumberListValue.parse('1 2')!.add(NumberListValue.parse('10 20')!)!.toAttributeValue(),
        '11 22',
      );
      expect(NumberListValue.parse('0 0')!.distanceTo(NumberListValue.parse('3 4')!), 5);
    });
  });

  group('ColorValue', () {
    test('parses every interpolable color syntax', () {
      expect(ColorValue.parse('#f00')!.argb, 0xFFFF0000);
      expect(ColorValue.parse('#00ff00')!.argb, 0xFF00FF00);
      expect(ColorValue.parse('#0000ff80')!.argb, 0x800000FF);
      expect(ColorValue.parse('rgb(255, 0, 0)')!.argb, 0xFFFF0000);
      expect(ColorValue.parse('rgba(0, 0, 255, 0.5)')!.alpha, 128);
      expect(ColorValue.parse('rgb(100%, 0%, 0%)')!.argb, 0xFFFF0000);
      expect(ColorValue.parse('hsl(0, 100%, 50%)')!.argb, 0xFFFF0000);
      expect(ColorValue.parse('red')!.argb, 0xFFFF0000);
      expect(ColorValue.parse('darkslateblue')!.argb, 0xFF483D8B);
    });

    test('rejects values that are not colors', () {
      expect(ColorValue.parse('none'), isNull);
      expect(ColorValue.parse('currentColor'), isNull);
      expect(ColorValue.parse('url(#gradient)'), isNull);
    });

    test('interpolates per channel and serializes as hex', () {
      final AnimatableValue black = ColorValue.parse('#000000')!;
      final AnimatableValue white = ColorValue.parse('#ffffff')!;
      expect(black.lerp(white, 0.5)!.toAttributeValue(), '#808080');
      expect(black.lerp(white, 1)!.toAttributeValue(), '#ffffff');
    });

    test('keeps alpha in the serialized form only when it is not opaque', () {
      expect(const ColorValue(0xFF102030).toAttributeValue(), '#102030');
      expect(const ColorValue(0x80102030).toAttributeValue(), '#10203080');
    });
  });

  group('TransformListValue', () {
    test('parses SVG transform lists', () {
      final TransformListValue value = TransformListValue.parse('translate(10 20) rotate(45)')!;
      expect(value.transforms.length, 2);
      expect(value.toAttributeValue(), 'translate(10 20) rotate(45)');
    });

    test('normalizes CSS spellings to SVG ones', () {
      expect(TransformListValue.parse('rotate(90deg)')!.toAttributeValue(), 'rotate(90)');
      expect(TransformListValue.parse('rotate(0.5turn)')!.toAttributeValue(), 'rotate(180)');
      expect(TransformListValue.parse('translateX(10px)')!.toAttributeValue(), 'translate(10 0)');
      expect(TransformListValue.parse('scaleY(2)')!.toAttributeValue(), 'scale(1 2)');
    });

    test('rejects transforms that depend on the element box', () {
      expect(TransformListValue.parse('translate(50%)'), isNull);
      expect(TransformListValue.parse('none'), isNull);
      expect(TransformListValue.parse('perspective(10px)'), isNull);
    });

    test('interpolates matching function lists only', () {
      final AnimatableValue from = TransformListValue.parse('rotate(0)')!;
      final AnimatableValue to = TransformListValue.parse('rotate(90)')!;
      expect(from.lerp(to, 0.5)!.toAttributeValue(), 'rotate(45)');
      expect(from.lerp(TransformListValue.parse('scale(2)')!, 0.5), isNull);
    });

    test('pads shorthand arities so rotate about a point interpolates', () {
      final AnimatableValue from = TransformListValue.parse('rotate(0)')!;
      final AnimatableValue to = TransformListValue.parse('rotate(360 50 50)')!;
      expect(from.lerp(to, 0.5)!.toAttributeValue(), 'rotate(180 25 25)');
    });

    test('drops arguments past what the transform type accepts', () {
      // The SVG parser these values feed rejects an over-long argument list, so
      // the extra arguments are dropped rather than failing the whole picture.
      expect(
        TransformListValue.parse('rotate(45 50 50 99)')!.toAttributeValue(),
        'rotate(45 50 50)',
      );
      expect(TransformListValue.parse('translate(1 2 3)')!.toAttributeValue(), 'translate(1 2)');

      final AnimatableValue from = TransformListValue.parse('rotate(0 50 50 0)')!;
      final AnimatableValue to = TransformListValue.parse('rotate(360 50 50)')!;
      expect(from.lerp(to, 0.5)!.toAttributeValue(), 'rotate(180 50 50)');
      expect(from.distanceTo(to), isNotNull);
      expect(
        TransformListValue.parse(
          'translate(1 2 3)',
        )!.add(TransformListValue.parse('translate(4 5 6)')!)!.toAttributeValue(),
        'translate(5 7)',
      );
    });

    test('composes by concatenation', () {
      final AnimatableValue base = TransformListValue.parse('translate(5 5)')!;
      final AnimatableValue added = TransformListValue.parse('rotate(90)')!;
      expect(base.compose(added)!.toAttributeValue(), 'translate(5 5) rotate(90)');
    });

    test('adds component-wise, and multiplies scale factors', () {
      expect(
        TransformListValue.parse(
          'translate(5 5)',
        )!.add(TransformListValue.parse('translate(1 2)')!)!.toAttributeValue(),
        'translate(6 7)',
      );
      expect(
        TransformListValue.parse(
          'scale(2)',
        )!.add(TransformListValue.parse('scale(3)')!)!.toAttributeValue(),
        'scale(6)',
      );
      expect(
        TransformListValue.parse('rotate(10)')!.add(TransformListValue.parse('scale(2)')!),
        isNull,
      );
    });
  });

  group('parseAnimatableValue', () {
    test('reads color attributes as colors', () {
      expect(parseAnimatableValue('fill', 'red'), isA<ColorValue>());
      expect(parseAnimatableValue('stroke', '#123456'), isA<ColorValue>());
      expect(parseAnimatableValue('stop-color', 'blue'), isA<ColorValue>());
    });

    test('reads other attributes as numbers when it can', () {
      expect(parseAnimatableValue('opacity', '0.5'), isA<NumberListValue>());
      expect(parseAnimatableValue('r', '10'), isA<NumberListValue>());
    });

    test('falls back to a keyword that animates discretely', () {
      final AnimatableValue value = parseAnimatableValue('fill', 'none');
      expect(value, isA<KeywordValue>());
      final AnimatableValue other = parseAnimatableValue('fill', 'currentColor');
      expect(value.lerp(other, 0.4), value);
      expect(value.lerp(other, 1), other);
    });
  });
}
