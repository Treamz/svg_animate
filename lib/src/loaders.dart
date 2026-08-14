import 'dart:convert' show utf8;
import 'dart:io' show File;

import 'package:flutter/foundation.dart' hide compute;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart' show ColorMapper, DefaultSvgTheme, SvgTheme;
import 'package:http/http.dart' as http;

import 'utilities/compute.dart';

/// The SVG markup a loader provides, along with everything needed to compile
/// it.
@immutable
class SvgSource {
  /// Creates a source description.
  const SvgSource({required this.xml, required this.theme, required this.colorMapper});

  /// The SVG markup.
  final String xml;

  /// The theme that resolves `currentColor` and font relative units.
  final SvgTheme theme;

  /// The color mapper to apply while compiling, if any.
  final ColorMapper? colorMapper;
}

/// Provides the SVG markup for an [AnimatedSvgPicture] to animate.
///
/// Unlike the loaders in `package:flutter_svg`, which produce an already
/// compiled vector graphic, these provide the markup itself: the animations a
/// document declares have to be resolved before it can be compiled.
///
/// Implementations must be immutable and must define value equality, because
/// the compiled frames are cached against them.
@immutable
abstract class SvgSourceLoader<T> {
  /// See class doc.
  const SvgSourceLoader({this.theme, this.colorMapper});

  /// The theme that determines `currentColor` and font relative sizing.
  ///
  /// When null, the theme comes from an enclosing [DefaultSvgTheme], and
  /// failing that from the default [SvgTheme].
  final SvgTheme? theme;

  /// The color mapper to apply while compiling, if any.
  final ColorMapper? colorMapper;

  /// Fetches whatever the SVG markup has to be read from, if anything.
  ///
  /// Runs on the main isolate, because it may need [context].
  @protected
  Future<T?> prepareMessage(BuildContext? context) => SynchronousFuture<T?>(null);

  /// Turns the result of [prepareMessage] into SVG markup.
  ///
  /// Runs in a background isolate where the platform supports it.
  @protected
  String provideSvg(T? message);

  /// The theme to compile with, resolved against [context].
  @protected
  SvgTheme resolveTheme(BuildContext? context) {
    if (theme != null) {
      return theme!;
    }
    if (context != null) {
      final SvgTheme? defaultTheme = DefaultSvgTheme.of(context)?.theme;
      if (defaultTheme != null) {
        return defaultTheme;
      }
    }
    return const SvgTheme();
  }

  /// Loads the markup this loader provides.
  Future<SvgSource> loadSvgSource(BuildContext? context) {
    final SvgTheme resolved = resolveTheme(context);
    return prepareMessage(context).then((T? message) {
      return compute(provideSvg, message, debugLabel: 'Load SVG source').then((String xml) {
        return SvgSource(xml: xml, theme: resolved, colorMapper: colorMapper);
      });
    });
  }

  /// Identifies this loader for caching.
  ///
  /// Loaders that resolve anything from the [BuildContext] must fold it into
  /// the key.
  Object cacheKey(BuildContext? context) => this;
}

/// Loads SVG markup from a string.
class SvgAnimateStringLoader extends SvgSourceLoader<void> {
  /// See class doc.
  const SvgAnimateStringLoader(this.source, {super.theme, super.colorMapper});

  /// The SVG markup.
  final String source;

  @override
  String provideSvg(void message) => source;

  @override
  bool operator ==(Object other) =>
      other is SvgAnimateStringLoader &&
      other.source == source &&
      other.theme == theme &&
      other.colorMapper == colorMapper;

  @override
  int get hashCode => Object.hash(source, theme, colorMapper);

  @override
  String toString() => 'SvgAnimateStringLoader(${source.length} chars)';
}

/// Loads SVG markup from UTF-8 encoded bytes.
class SvgAnimateBytesLoader extends SvgSourceLoader<void> {
  /// See class doc.
  const SvgAnimateBytesLoader(this.bytes, {super.theme, super.colorMapper});

  /// The UTF-8 encoded markup.
  final Uint8List bytes;

  @override
  String provideSvg(void message) => utf8.decode(bytes, allowMalformed: true);

  @override
  bool operator ==(Object other) =>
      other is SvgAnimateBytesLoader &&
      other.bytes == bytes &&
      other.theme == theme &&
      other.colorMapper == colorMapper;

  @override
  int get hashCode => Object.hash(bytes, theme, colorMapper);

  @override
  String toString() => 'SvgAnimateBytesLoader(${bytes.length} bytes)';
}

/// Loads SVG markup from an [AssetBundle].
class SvgAnimateAssetLoader extends SvgSourceLoader<ByteData> {
  /// See class doc.
  const SvgAnimateAssetLoader(
    this.assetName, {
    this.packageName,
    this.assetBundle,
    super.theme,
    super.colorMapper,
  });

  /// The name of the asset, such as `assets/spinner.svg`.
  final String assetName;

  /// The package the asset lives in, if it is not the app's own.
  final String? packageName;

  /// The bundle to load from, or the enclosing [DefaultAssetBundle] if null.
  final AssetBundle? assetBundle;

  AssetBundle _resolveBundle(BuildContext? context) {
    if (assetBundle != null) {
      return assetBundle!;
    }
    if (context != null) {
      return DefaultAssetBundle.of(context);
    }
    return rootBundle;
  }

  @override
  Future<ByteData?> prepareMessage(BuildContext? context) {
    return _resolveBundle(
      context,
    ).load(packageName == null ? assetName : 'packages/$packageName/$assetName');
  }

  @override
  String provideSvg(ByteData? message) =>
      utf8.decode(Uint8List.sublistView(message!), allowMalformed: true);

  @override
  Object cacheKey(BuildContext? context) =>
      _AssetKey(assetName, packageName, _resolveBundle(context), theme, colorMapper);

  @override
  bool operator ==(Object other) =>
      other is SvgAnimateAssetLoader &&
      other.assetName == assetName &&
      other.packageName == packageName &&
      other.assetBundle == assetBundle &&
      other.theme == theme &&
      other.colorMapper == colorMapper;

  @override
  int get hashCode => Object.hash(assetName, packageName, assetBundle, theme, colorMapper);

  @override
  String toString() => 'SvgAnimateAssetLoader($assetName)';
}

/// The bundle a [DefaultAssetBundle] resolves to is part of an asset's
/// identity, so it has to be part of the cache key too.
@immutable
class _AssetKey {
  const _AssetKey(this.assetName, this.packageName, this.assetBundle, this.theme, this.colorMapper);

  final String assetName;
  final String? packageName;
  final AssetBundle assetBundle;
  final SvgTheme? theme;
  final ColorMapper? colorMapper;

  @override
  bool operator ==(Object other) =>
      other is _AssetKey &&
      other.assetName == assetName &&
      other.packageName == packageName &&
      other.assetBundle == assetBundle &&
      other.theme == theme &&
      other.colorMapper == colorMapper;

  @override
  int get hashCode => Object.hash(assetName, packageName, assetBundle, theme, colorMapper);
}

/// Loads SVG markup from a file.
class SvgAnimateFileLoader extends SvgSourceLoader<void> {
  /// See class doc.
  const SvgAnimateFileLoader(this.file, {super.theme, super.colorMapper});

  /// The file holding the markup.
  final File file;

  @override
  String provideSvg(void message) => utf8.decode(file.readAsBytesSync(), allowMalformed: true);

  // Compares paths rather than [File] objects, which do not define value
  // equality; without this a loader created in a build method would never match
  // the one it replaces, and nothing would ever be served from the cache.
  @override
  bool operator ==(Object other) =>
      other is SvgAnimateFileLoader &&
      other.file.path == file.path &&
      other.theme == theme &&
      other.colorMapper == colorMapper;

  @override
  int get hashCode => Object.hash(file.path, theme, colorMapper);

  @override
  String toString() => 'SvgAnimateFileLoader(${file.path})';
}

/// Loads SVG markup over HTTP.
///
/// Responses are cached regardless of their HTTP headers, for as long as the
/// compiled animation stays in the cache.
class SvgAnimateNetworkLoader extends SvgSourceLoader<Uint8List> {
  /// See class doc.
  const SvgAnimateNetworkLoader(
    this.url, {
    this.headers,
    super.theme,
    super.colorMapper,
    http.Client? httpClient,
  }) : _httpClient = httpClient;

  /// The address to fetch.
  final String url;

  /// Headers to send with the request.
  final Map<String, String>? headers;

  final http.Client? _httpClient;

  @override
  Future<Uint8List?> prepareMessage(BuildContext? context) async {
    final http.Client client = _httpClient ?? http.Client();
    try {
      final http.Response response = await client.get(Uri.parse(url), headers: headers);
      return response.bodyBytes;
    } finally {
      if (_httpClient == null) {
        client.close();
      }
    }
  }

  @override
  String provideSvg(Uint8List? message) => utf8.decode(message!, allowMalformed: true);

  @override
  bool operator ==(Object other) =>
      other is SvgAnimateNetworkLoader &&
      other.url == url &&
      other.headers == headers &&
      other.theme == theme &&
      other.colorMapper == colorMapper;

  @override
  int get hashCode => Object.hash(url, headers, theme, colorMapper);

  @override
  String toString() => 'SvgAnimateNetworkLoader($url)';
}
