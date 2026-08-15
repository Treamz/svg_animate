import 'package:flutter/material.dart';
import 'package:svg_animate/svg_animate.dart';

/// Names and descriptions of the animated SVGs shipped with this example.
const Map<String, String> _assets = <String, String>{
  'assets/spinner.svg': 'SMIL: <animateTransform> and <animate>',
  'assets/pulse.svg': 'CSS: @keyframes with transform-origin',
  'assets/orbit.svg': 'SMIL: <animateMotion> along an <mpath>',
  'assets/progress.svg': 'SMIL: <animateMotion> along an <mpath>',
};

void main() {
  runApp(const AnimatedSvgExampleApp());
}

/// An example app that plays the animated SVGs in `assets/animated`.
class AnimatedSvgExampleApp extends StatelessWidget {
  /// Creates the example app.
  const AnimatedSvgExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Animated SVG',
      home: Scaffold(
        appBar: AppBar(title: const Text('Animated SVG')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            for (final MapEntry<String, String> asset in _assets.entries)
              _Sample(assetName: asset.key, description: asset.value),
            // const Divider(height: 48),
            // const _ControlledSample(),
          ],
        ),
      ),
    );
  }
}

class _Sample extends StatelessWidget {
  const _Sample({required this.assetName, required this.description});

  final String assetName;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsetsGeometry.symmetric(vertical: 10),
      child: AnimatedSvgPicture.asset(assetName, width: 80, height: 80),
    );
  }
}

/// Demonstrates driving an animation from outside the widget, so that it can be
/// paused and scrubbed.
class _ControlledSample extends StatefulWidget {
  const _ControlledSample();

  @override
  State<_ControlledSample> createState() => _ControlledSampleState();
}

class _ControlledSampleState extends State<_ControlledSample> {
  final AnimatedSvgController _controller = AnimatedSvgController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleControllerChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_handleControllerChanged)
      ..dispose();
    super.dispose();
  }

  void _handleControllerChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Driven by an AnimatedSvgController'),
        ),
        const SizedBox(height: 16),
        Center(
          child: AnimatedSvgPicture.asset(
            'assets/progress.svg',
            width: 240,
            repeat: false,
            controller: _controller,
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            IconButton(
              icon: Icon(
                _controller.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
              onPressed: _controller.isPlaying
                  ? _controller.pause
                  : _controller.play,
            ),
            IconButton(
              icon: const Icon(Icons.stop),
              onPressed: _controller.stop,
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: _controller.progress,
                builder: (BuildContext context, Widget? child) {
                  return Slider(
                    value: _controller.progress.value,
                    onChanged: (double value) {
                      _controller.pause();
                      _controller.seek(value);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}
