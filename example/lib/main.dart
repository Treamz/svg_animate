import 'package:flutter/material.dart';
import 'package:svg_animate/svg_animate.dart';

import 'playback_controls.dart';
import 'playground.dart';

/// Names and descriptions of the animated SVGs shipped with this example.
const Map<String, String> _assets = <String, String>{
  'assets/spinner.svg': 'SMIL: <animateTransform> and <animate>',
  'assets/pulse.svg': 'CSS: @keyframes with transform-origin',
  'assets/orbit.svg': 'SMIL: <animateMotion> along an <mpath>',
  'assets/progress.svg': 'SMIL: <animate> on width, with rounded ends',
};

void main() {
  runApp(const AnimatedSvgExampleApp());
}

/// An example app that plays the animated SVGs in `assets/`, and lets a visitor
/// try one of their own.
class AnimatedSvgExampleApp extends StatelessWidget {
  /// Creates the example app.
  const AnimatedSvgExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Animated SVG',
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Animated SVG'),
            bottom: const TabBar(
              tabs: <Widget>[
                Tab(text: 'Samples'),
                Tab(text: 'Try your own'),
              ],
            ),
          ),
          body: const TabBarView(
            children: <Widget>[_SamplesScreen(), PlaygroundScreen()],
          ),
        ),
      ),
    );
  }
}

/// The animated SVGs that ship with the example.
class _SamplesScreen extends StatelessWidget {
  const _SamplesScreen();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        for (final MapEntry<String, String> asset in _assets.entries)
          _Sample(assetName: asset.key, description: asset.value),
        const Divider(height: 48),
        const _ControlledSample(),
      ],
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
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          AnimatedSvgPicture.asset(assetName, width: 80, height: 80),
          const SizedBox(width: 16),
          // What each sample is there to demonstrate. It was being passed in
          // and then not shown, which left four unlabelled shapes.
          Expanded(child: Text(description)),
        ],
      ),
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
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

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
        PlaybackControls(controller: _controller),
      ],
    );
  }
}
