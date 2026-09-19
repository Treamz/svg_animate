import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:svg_animate/svg_animate.dart';

import 'playback_controls.dart';

/// Plays an SVG the visitor supplies, and says what compiling it produced.
///
/// The samples shipped with this example are ones that were chosen because they
/// work. This is the other half: bring a file of your own and find out, without
/// adding the package to an app first, whether it plays — and if it does not,
/// which of the reasons it is, since an animation that does not play looks
/// exactly the same whatever the reason.
class PlaygroundScreen extends StatefulWidget {
  /// See class doc.
  const PlaygroundScreen({super.key});

  @override
  State<PlaygroundScreen> createState() => _PlaygroundScreenState();
}

/// Where the SVG being tried comes from.
enum _Source {
  /// Chosen from disk, and read as bytes rather than as a path, which is all a
  /// browser will give.
  file('File'),

  /// Fetched over the network, subject to the remote server allowing it.
  url('URL'),

  /// Pasted in. The only one of the three that cannot be refused by anything.
  markup('Paste');

  const _Source(this.label);

  final String label;
}

/// An SVG large enough that compiling it would lock a browser tab up for long
/// enough to look like a crash. Refused with an explanation instead.
const int _maximumSourceBytes = 4 << 20;

/// Prefilled because a URL that works is worth more here than an empty field:
/// raw.githubusercontent.com is one of the few hosts that lets a page on
/// another domain read from it.
const String _exampleUrl =
    'https://raw.githubusercontent.com/Treamz/svg_animate/main/example/assets/spinner.svg';

/// An SVG that plays, and asks for something that will not be drawn.
///
/// Deliberately not in `assets/`: everything under there is checked to compile
/// with no diagnostics at all, and this one exists to produce one. A visitor
/// with nothing of their own to try can still see what the package says when
/// a file asks for more than the renderer can give.
const String filterExample = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120" width="120" height="120">
  <defs>
    <filter id="glow" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="4"/>
    </filter>
  </defs>
  <circle cx="60" cy="60" r="26" fill="#42a5f5" filter="url(#glow)">
    <animate attributeName="r" values="18;30;18" dur="2s" repeatCount="indefinite"/>
  </circle>
  <circle cx="60" cy="60" r="12" fill="#0d47a1"/>
</svg>
''';

class _PlaygroundScreenState extends State<PlaygroundScreen> {
  final AnimatedSvgController _controller = AnimatedSvgController();
  final TextEditingController _url = TextEditingController(text: _exampleUrl);
  final TextEditingController _markup = TextEditingController();

  _Source _source = _Source.file;

  /// What is being shown, or null when nothing has loaded.
  SvgSourceLoader<Object?>? _loader;
  AnimatedSvgFrames? _frames;
  String? _name;

  Object? _error;
  bool _loading = false;

  /// Which attempt is the current one.
  ///
  /// Two loads can be in flight at once — a slow URL and then a file chosen
  /// while it is still going — and the one that finishes second is not
  /// necessarily the one that was asked for last.
  int _attempt = 0;

  @override
  void dispose() {
    _controller.dispose();
    _url.dispose();
    _markup.dispose();
    super.dispose();
  }

  /// Compiles [loader] and shows whatever came of it.
  ///
  /// Compiled here rather than left to the widget so that the frame count, the
  /// size and the diagnostics can be shown next to the picture; the widget then
  /// finds the animation in the shared cache instead of compiling it twice.
  Future<void> _show(SvgSourceLoader<Object?> loader, String name) async {
    final int attempt = ++_attempt;
    // Whatever was asked of the last animation — paused half way through,
    // say — is not what should happen to the next one.
    _controller
      ..seek(0)
      ..play();
    setState(() {
      _loading = true;
      _error = null;
      _frames = null;
      _loader = null;
      _name = name;
    });

    try {
      final AnimatedSvgFrames frames = await precacheAnimatedSvg(
        loader,
        context,
      );
      if (!mounted || attempt != _attempt) {
        return;
      }
      setState(() {
        _frames = frames;
        _loader = loader;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || attempt != _attempt) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _fail(String message) {
    if (!mounted) {
      return; // Reachable after an await, so the tab may already be gone.
    }
    _attempt++; // Anything still in flight is no longer what is being asked for.
    setState(() {
      _loading = false;
      _frames = null;
      _loader = null;
      _error = message;
    });
  }

  Future<void> _pickFile() async {
    final PlatformFile? file;
    try {
      file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: <String>['svg'],
      );
    } on Object catch (error) {
      _fail('That file could not be opened.\n\n$error');
      return;
    }
    if (file == null) {
      return; // Cancelled.
    }

    try {
      // Asked before reading: the picker usually knows the size already, and
      // where it does not this is still cheaper than compiling the thing.
      final int size = await file.length();
      if (size > _maximumSourceBytes) {
        _fail(
          '${file.name} is ${_describeBytes(size)}, and this demo stops at '
          '${_describeBytes(_maximumSourceBytes)}. Compiling one that size takes long '
          'enough to look like the page has hung. The package itself has no such limit.',
        );
        return;
      }

      // The list is held in state rather than rebuilt, because a bytes loader
      // compares by identity: a fresh list with the same contents is a
      // different animation as far as the cache is concerned, and would
      // recompile on every rebuild.
      final Uint8List bytes = await file.readAsBytes();
      if (!mounted) {
        return;
      }
      await _show(SvgAnimateBytesLoader(bytes), file.name);
    } on Object catch (error) {
      _fail('That file could not be read.\n\n$error');
    }
  }

  Future<void> _loadUrl() async {
    final String url = _url.text.trim();
    if (url.isEmpty) {
      _fail('Enter the address of an SVG.');
      return;
    }
    await _show(SvgAnimateNetworkLoader(url), url);
  }

  /// Loads the bundled SVG that asks for a blur.
  ///
  /// Into the text field as well as into the picture, so that what produced the
  /// diagnostic can be read and edited rather than only described.
  Future<void> _loadFilterExample() async {
    setState(() {
      _source = _Source.markup;
      _markup.text = filterExample;
    });
    await _show(
      const SvgAnimateStringLoader(filterExample),
      'an SVG asking for a blur',
    );
  }

  Future<void> _loadMarkup() async {
    final String markup = _markup.text.trim();
    if (markup.isEmpty) {
      _fail('Paste the contents of an SVG file.');
      return;
    }
    await _show(SvgAnimateStringLoader(markup), 'pasted markup');
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(
          'Load an SVG of your own and see whether it plays.',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        SegmentedButton<_Source>(
          segments: <ButtonSegment<_Source>>[
            for (final _Source source in _Source.values)
              ButtonSegment<_Source>(value: source, label: Text(source.label)),
          ],
          selected: <_Source>{_source},
          onSelectionChanged: (Set<_Source> selection) {
            setState(() {
              _source = selection.first;
              // A failure belongs to the way it was being loaded, so it should
              // not still be on the screen under a different one. What loaded
              // successfully stays: it is worth going on looking at.
              _error = null;
            });
          },
        ),
        const SizedBox(height: 16),
        _input(),
        const SizedBox(height: 8),
        _ExampleHint(onPressed: _loadFilterExample),
        const SizedBox(height: 16),
        _result(),
      ],
    );
  }

  Widget _input() {
    switch (_source) {
      case _Source.file:
        return Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _pickFile,
            icon: const Icon(Icons.folder_open),
            label: const Text('Choose an SVG file'),
          ),
        );
      case _Source.url:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              onSubmitted: (String _) => _loadUrl(),
              decoration: const InputDecoration(
                labelText: 'Address of an SVG',
                border: OutlineInputBorder(),
                helperMaxLines: 3,
                helperText: kIsWeb
                    ? 'In a browser this only works when the server allows it; '
                          'raw.githubusercontent.com does.'
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _loadUrl, child: const Text('Load')),
          ],
        );
      case _Source.markup:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _markup,
              minLines: 5,
              maxLines: 10,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                labelText: 'The contents of an SVG file',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _loadMarkup, child: const Text('Load')),
          ],
        );
    }
  }

  Widget _result() {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }

    final Object? error = _error;
    if (error != null) {
      return _Problem(message: _describeError(error));
    }

    final AnimatedSvgFrames? frames = _frames;
    final SvgSourceLoader<Object?>? loader = _loader;
    if (frames == null || loader == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(_name!, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              height: 240,
              // The loader is the one that was just compiled, so this finds the
              // animation in the cache rather than building it a second time.
              child: AnimatedSvgPicture(
                loader,
                fit: BoxFit.contain,
                controller: _controller,
              ),
            ),
          ),
        ),
        if (frames.isAnimated) PlaybackControls(controller: _controller),
        const SizedBox(height: 8),
        _Report(frames: frames),
      ],
    );
  }

  String _describeError(Object error) {
    if (error is String) {
      return error;
    }
    final String described = error.toString();
    if (_source == _Source.url && kIsWeb) {
      // Every failure to read a URL from a page looks the same from here, and
      // in a browser this is overwhelmingly which one it was.
      return '$described\n\nA page may only read a file from another site when '
          'that site says so, with an Access-Control-Allow-Origin header, and most '
          'do not. raw.githubusercontent.com does. Otherwise open the file and paste '
          'it in instead — nothing can refuse that.';
    }
    return described;
  }
}

/// Offers the bundled example to somebody who has nothing of their own.
///
/// What it is there for is the second half: an SVG that plays and still does
/// not look right is the case this page is worth opening for, and a visitor
/// with a working file of their own never sees it.
class _ExampleHint extends StatelessWidget {
  const _ExampleHint({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          'Nothing to hand? Try one that asks for a blur, which cannot be drawn:',
          style: theme.textTheme.bodySmall,
        ),
        TextButton(onPressed: onPressed, child: const Text('load it')),
      ],
    );
  }
}

/// The animation as it came out of the compiler.
class _Report extends StatelessWidget {
  const _Report({required this.frames});

  final AnimatedSvgFrames frames;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 24,
          runSpacing: 12,
          children: <Widget>[
            _Stat('Frames', '${frames.frameCount}'),
            // Worth showing beside the frame count: an animation the renderer
            // cannot express samples to any number of frames that are all the
            // same picture, and this is where that shows up.
            _Stat('Distinct', '${frames.distinctFrameCount}'),
            _Stat(
              'Duration',
              '${(frames.duration.inMilliseconds / 1000).toStringAsFixed(2)} s',
            ),
            _Stat('Compiled', _describeBytes(frames.compiledByteSize)),
            _Stat('Loops', frames.loops ? 'yes' : 'no'),
          ],
        ),
        for (final SvgAnimateDiagnostic diagnostic
            in frames.diagnostics) ...<Widget>[
          const SizedBox(height: 16),
          _Problem(message: diagnostic.message, icon: Icons.info_outline),
        ],
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label.toUpperCase(), style: theme.textTheme.labelSmall),
        Text(value, style: theme.textTheme.titleMedium),
      ],
    );
  }
}

/// Something the visitor should read: a failure, or something in the SVG that
/// will not happen.
class _Problem extends StatelessWidget {
  const _Problem({required this.message, this.icon = Icons.error_outline});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: SelectableText(message, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}

String _describeBytes(int value) {
  if (value < 1024) {
    return '$value B';
  }
  if (value < 1024 * 1024) {
    return '${(value / 1024).toStringAsFixed(1)} KB';
  }
  return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
}
