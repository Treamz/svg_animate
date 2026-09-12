import 'dart:convert' show utf8;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart' show ColorMapper, DefaultSvgTheme, SvgTheme;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:svg_animate/svg_animate.dart';

const String markup = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"/>';

/// Serves whatever it is given, and remembers what was asked of it.
class _Bundle extends CachingAssetBundle {
  _Bundle(this.contents);

  final Map<String, String> contents;
  final List<String> requested = <String>[];

  @override
  Future<ByteData> load(String key) async {
    requested.add(key);
    final String? value = contents[key];
    if (value == null) {
      throw FlutterError('no asset "$key"');
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(value)));
  }
}

/// Turns every colour black, and is worth nothing except being a value that can
/// be compared.
class _Mapper extends ColorMapper {
  const _Mapper();

  @override
  Color substitute(String? id, String elementName, String attributeName, Color color) =>
      const Color(0xFF000000);
}

void main() {
  group('the markup a loader provides', () {
    test('a string is handed over as it is', () async {
      final SvgSource source = await const SvgAnimateStringLoader(markup).loadSvgSource(null);
      expect(source.xml, markup);
    });

    test('bytes are decoded as UTF-8', () async {
      final SvgSource source = await SvgAnimateBytesLoader(
        Uint8List.fromList(utf8.encode(markup)),
      ).loadSvgSource(null);
      expect(source.xml, markup);
    });

    test('bytes that are not valid UTF-8 are decoded anyway', () async {
      // An SVG that arrives mis-encoded should draw what can be read of it
      // rather than throwing, which is what `allowMalformed` is there for.
      final SvgSource source = await SvgAnimateBytesLoader(
        Uint8List.fromList(<int>[...utf8.encode(markup), 0xC3]),
      ).loadSvgSource(null);
      expect(source.xml, startsWith('<svg'));
    });

    test('an asset is read from the bundle', () async {
      final _Bundle bundle = _Bundle(<String, String>{'assets/a.svg': markup});
      final SvgSource source = await SvgAnimateAssetLoader(
        'assets/a.svg',
        assetBundle: bundle,
      ).loadSvgSource(null);

      expect(source.xml, markup);
      expect(bundle.requested, <String>['assets/a.svg']);
    });

    test('an asset in another package is asked for under packages/', () async {
      final _Bundle bundle = _Bundle(<String, String>{'packages/other/assets/a.svg': markup});
      await SvgAnimateAssetLoader(
        'assets/a.svg',
        packageName: 'other',
        assetBundle: bundle,
      ).loadSvgSource(null);

      expect(bundle.requested, <String>['packages/other/assets/a.svg']);
    });

    test('a file is read from disk', () async {
      final Directory directory = Directory.systemTemp.createTempSync('svg_animate_test');
      addTearDown(() => directory.deleteSync(recursive: true));
      final File file = File('${directory.path}/a.svg')..writeAsStringSync(markup);

      final SvgSource source = await SvgAnimateFileLoader(file).loadSvgSource(null);
      expect(source.xml, markup);
    });

    test('a network response is decoded, and the headers are sent', () async {
      late Map<String, String> sent;
      final MockClient client = MockClient((http.Request request) async {
        sent = request.headers;
        expect(request.url.toString(), 'https://example.com/a.svg');
        return http.Response(markup, 200);
      });

      final SvgSource source = await SvgAnimateNetworkLoader(
        'https://example.com/a.svg',
        headers: const <String, String>{'x-token': 'abc'},
        httpClient: client,
      ).loadSvgSource(null);

      expect(source.xml, markup);
      expect(sent['x-token'], 'abc');
    });
  });

  group('the theme a loader compiles with', () {
    const SvgTheme theirs = SvgTheme(currentColor: Color(0xFF00FF00));

    test('is the one it was given', () async {
      final SvgSource source = await const SvgAnimateStringLoader(
        markup,
        theme: theirs,
      ).loadSvgSource(null);
      expect(source.theme, theirs);
    });

    test('falls back to the default when there is neither a theme nor a context', () async {
      final SvgSource source = await const SvgAnimateStringLoader(markup).loadSvgSource(null);
      expect(source.theme, const SvgTheme());
    });

    testWidgets('comes from an enclosing DefaultSvgTheme otherwise', (WidgetTester tester) async {
      BuildContext? captured;
      await tester.pumpWidget(
        DefaultSvgTheme(
          theme: theirs,
          child: Builder(
            builder: (BuildContext context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );

      final SvgSource source = await const SvgAnimateStringLoader(markup).loadSvgSource(captured!);
      expect(source.theme, theirs);
    });
  });

  // What the compiled frames are cached against. A loader that fails to equal
  // the one it replaces recompiles the whole animation on every rebuild, which
  // for a large SVG is seconds of work and raises nothing at all.
  group('what a loader equals', () {
    test('two strings with the same markup and theme', () {
      expect(const SvgAnimateStringLoader(markup), equals(const SvgAnimateStringLoader(markup)));
      expect(
        const SvgAnimateStringLoader(markup).hashCode,
        const SvgAnimateStringLoader(markup).hashCode,
      );
    });

    test('and not one with a different theme or mapper', () {
      const SvgAnimateStringLoader plain = SvgAnimateStringLoader(markup);
      expect(
        plain,
        isNot(
          const SvgAnimateStringLoader(markup, theme: SvgTheme(currentColor: Color(0xFF00FF00))),
        ),
      );
      expect(plain, isNot(const SvgAnimateStringLoader(markup, colorMapper: _Mapper())));
    });

    test('two files at the same path, even as different File objects', () {
      // The reason this is compared by path: `File` has no value equality, so a
      // loader built in a build method would never match the one it replaced
      // and nothing would ever come out of the cache.
      expect(
        SvgAnimateFileLoader(File('/tmp/a.svg')),
        equals(SvgAnimateFileLoader(File('/tmp/a.svg'))),
      );
      expect(
        SvgAnimateFileLoader(File('/tmp/a.svg')),
        isNot(SvgAnimateFileLoader(File('/tmp/b.svg'))),
      );
    });

    test('two network loaders for the same url', () {
      expect(
        const SvgAnimateNetworkLoader('https://example.com/a.svg'),
        equals(const SvgAnimateNetworkLoader('https://example.com/a.svg')),
      );
      expect(
        const SvgAnimateNetworkLoader('https://example.com/a.svg'),
        isNot(const SvgAnimateNetworkLoader('https://example.com/b.svg')),
      );
    });

    test('two assets with the same name and bundle', () {
      final _Bundle bundle = _Bundle(const <String, String>{});
      expect(
        SvgAnimateAssetLoader('a.svg', assetBundle: bundle),
        equals(SvgAnimateAssetLoader('a.svg', assetBundle: bundle)),
      );
      expect(
        SvgAnimateAssetLoader('a.svg', assetBundle: bundle),
        isNot(SvgAnimateAssetLoader('a.svg', packageName: 'other', assetBundle: bundle)),
      );
    });

    test('bytes only when they are the same list', () {
      // Pinned rather than desired. `Uint8List` has no value equality, and
      // comparing a hundred kilobytes on every cache lookup would cost more
      // than it saves; `flutter_svg`'s own `SvgBytesLoader` compares the same
      // way. Hold on to one list rather than rebuilding it every frame.
      final Uint8List bytes = Uint8List.fromList(utf8.encode(markup));
      expect(SvgAnimateBytesLoader(bytes), equals(SvgAnimateBytesLoader(bytes)));
      expect(
        SvgAnimateBytesLoader(bytes),
        isNot(SvgAnimateBytesLoader(Uint8List.fromList(utf8.encode(markup)))),
        reason: 'equal contents in a different list are a different loader',
      );
    });

    test('network headers only when they are the same map, for the same reason', () {
      final Map<String, String> headers = <String, String>{'x-token': 'abc'};
      expect(
        SvgAnimateNetworkLoader('https://example.com/a.svg', headers: headers),
        equals(SvgAnimateNetworkLoader('https://example.com/a.svg', headers: headers)),
      );
      expect(
        SvgAnimateNetworkLoader('https://example.com/a.svg', headers: headers),
        isNot(
          SvgAnimateNetworkLoader(
            'https://example.com/a.svg',
            headers: <String, String>{'x-token': 'abc'},
          ),
        ),
        reason: 'the same headers in a different map are a different loader',
      );
    });

    test('but headers written as a const literal are one map, so they do match', () {
      // Worth pinning because it is why this trap is milder than it sounds:
      // headers are usually written inline, and Dart gives every identical
      // const map the same instance.
      expect(
        const SvgAnimateNetworkLoader(
          'https://example.com/a.svg',
          headers: <String, String>{'x-token': 'abc'},
        ),
        equals(
          const SvgAnimateNetworkLoader(
            'https://example.com/a.svg',
            headers: <String, String>{'x-token': 'abc'},
          ),
        ),
      );
    });
  });

  group('the key an asset is cached under', () {
    test('is the same for the same asset from the same bundle', () {
      final _Bundle bundle = _Bundle(const <String, String>{});
      final Object first = SvgAnimateAssetLoader('a.svg', assetBundle: bundle).cacheKey(null);
      final Object second = SvgAnimateAssetLoader('a.svg', assetBundle: bundle).cacheKey(null);

      expect(first, equals(second));
      expect(first.hashCode, second.hashCode);
    });

    test('differs when the bundle does', () {
      // Two bundles can hold different bytes under one name, so the bundle has
      // to be part of the key or one would be served for the other.
      expect(
        SvgAnimateAssetLoader(
          'a.svg',
          assetBundle: _Bundle(const <String, String>{}),
        ).cacheKey(null),
        isNot(
          SvgAnimateAssetLoader(
            'a.svg',
            assetBundle: _Bundle(const <String, String>{}),
          ).cacheKey(null),
        ),
      );
    });

    test('differs when the package does', () {
      final _Bundle bundle = _Bundle(const <String, String>{});
      expect(
        SvgAnimateAssetLoader('a.svg', assetBundle: bundle).cacheKey(null),
        isNot(
          SvgAnimateAssetLoader('a.svg', packageName: 'other', assetBundle: bundle).cacheKey(null),
        ),
      );
    });

    testWidgets('follows the DefaultAssetBundle when none was given', (WidgetTester tester) async {
      final _Bundle bundle = _Bundle(<String, String>{'a.svg': markup});
      BuildContext? captured;
      await tester.pumpWidget(
        DefaultAssetBundle(
          bundle: bundle,
          child: Builder(
            builder: (BuildContext context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );

      const SvgAnimateAssetLoader loader = SvgAnimateAssetLoader('a.svg');
      expect(loader.cacheKey(captured!), isNot(loader.cacheKey(null)));
      expect(await loader.loadSvgSource(captured!).then((SvgSource s) => s.xml), markup);
    });
  });
}
