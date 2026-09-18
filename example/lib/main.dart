import 'package:flutter/material.dart';
import 'package:svg_animate/svg_animate.dart';

import 'playback_controls.dart';
import 'playground.dart';

/// One of the animated SVGs shipped with this example.
class Sample {
  /// See class doc.
  const Sample(this.asset, this.title, this.description);

  /// The file under `assets/`.
  final String asset;

  /// What it is.
  final String title;

  /// What it is here to show, which is not always what it looks like: several
  /// of these are ordinary to watch and awkward to compile.
  final String description;
}

/// Ordered so that the ones doing something a still SVG cannot come first.
///
/// `progress.svg` is not in here: it is the one driven by a controller further
/// down the page, and showing it twice would say less rather than more.
const List<Sample> _samples = <Sample>[
  Sample(
    'assets/signature.svg',
    'Drawn on',
    'An animated stroke-dasharray. The dash grows to the length of the path while '
        'the gap after it shrinks away — a list of numbers interpolated as a list.',
  ),
  Sample(
    'assets/reveal.svg',
    'Wiped in',
    'Bars revealed by a clipPath whose rect gets wider and then narrows again. '
        'The clip is resolved for every frame, so the wipe is geometry rather '
        'than an effect.',
  ),
  Sample(
    'assets/gradient.svg',
    'Animated gradient',
    'The gradient itself moves: the stop colours change and so does where the '
        'middle stop sits.',
  ),
  Sample(
    'assets/bars.svg',
    'Started apart',
    'Five bars running the same animation, each held back by its own begin. There '
        'is no shared timeline; they simply agree.',
  ),
  Sample(
    'assets/bounce.svg',
    'Two transforms at once',
    'A fall and a squash on the same element, combined with additive="sum" and '
        'eased by keySplines rather than by a named curve.',
  ),
  Sample(
    'assets/comet.svg',
    'CSS motion path',
    'offset-path with offset-distance animated, and offset-rotate turning the '
        'shape to face the way it is going.',
  ),
  Sample(
    'assets/breathe.svg',
    'Alternating',
    'CSS animation-direction: alternate plays the keyframes forwards and then '
        'backwards, and animation-delay staggers the three circles.',
  ),
  Sample(
    'assets/orbit.svg',
    'SMIL motion path',
    'animateMotion along an mpath, with rotate="auto".',
  ),
  Sample(
    'assets/spinner.svg',
    'Spinner',
    'animateTransform turning an arc, with its stroke colour animated alongside '
        'it on a longer loop.',
  ),
  Sample(
    'assets/pulse.svg',
    'Pulse',
    'CSS @keyframes scaling about transform-origin: center, which is resolved '
        'against the view box.',
  ),
];

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
        for (final Sample sample in _samples) _SampleTile(sample: sample),
        const Divider(height: 48),
        const _ControlledSample(),
      ],
    );
  }
}

class _SampleTile extends StatelessWidget {
  const _SampleTile({required this.sample});

  final Sample sample;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          // A fixed box rather than the picture's own size: these are 48x48 and
          // 120x48, and a list where every row starts in a different place is
          // harder to read than one that wastes a little space.
          SizedBox(
            width: 104,
            height: 64,
            child: AnimatedSvgPicture.asset(
              sample.asset,
              fit: BoxFit.contain,
              // Half the default. A tile is 64 logical pixels tall, where 30
              // frames a second is not tellable from 60, and this page compiles
              // ten animations before it can show any of them — on the web that
              // happens on the one thread there is.
              frameRate: 30,
              // Without this the row is empty until its animation is compiled,
              // and a page of empty rows reads as broken rather than as busy.
              placeholderBuilder: (BuildContext context) => const _Skeleton(),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(sample.title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(sample.description, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Stands in for a sample while it is being compiled.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 64,
        height: 40,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
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
