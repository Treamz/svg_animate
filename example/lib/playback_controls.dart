import 'package:flutter/material.dart';
import 'package:svg_animate/svg_animate.dart';

/// Play, stop and a scrubber for an [AnimatedSvgController].
///
/// Shared by the bundled samples and by the playground so that an animation
/// somebody brings behaves exactly like the ones shipped with the example, and
/// so there is one place to look when it does not.
class PlaybackControls extends StatefulWidget {
  /// See class doc.
  const PlaybackControls({super.key, required this.controller});

  /// The playback being driven.
  final AnimatedSvgController controller;

  @override
  State<PlaybackControls> createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends State<PlaybackControls> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(PlaybackControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  // The controller reports starting and stopping, which is what the play button
  // draws. The position is not in there on purpose: it changes every frame, so
  // the slider listens to `progress` instead and only the slider rebuilds.
  void _handleControllerChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final AnimatedSvgController controller = widget.controller;
    return Row(
      children: <Widget>[
        IconButton(
          icon: Icon(controller.isPlaying ? Icons.pause : Icons.play_arrow),
          tooltip: controller.isPlaying ? 'Pause' : 'Play',
          onPressed: controller.isPlaying ? controller.pause : controller.play,
        ),
        IconButton(
          icon: const Icon(Icons.stop),
          tooltip: 'Back to the first frame',
          onPressed: controller.stop,
        ),
        Expanded(
          child: AnimatedBuilder(
            animation: controller.progress,
            builder: (BuildContext context, Widget? child) {
              return Slider(
                value: controller.progress.value,
                onChanged: (double value) {
                  controller.pause();
                  controller.seek(value);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
