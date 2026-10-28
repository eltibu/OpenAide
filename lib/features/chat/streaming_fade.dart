/// Settings > Interface > Fade in streaming text: while a reply is being
/// written, its newest line fades in instead of popping, as the web's
/// fade effect.
library;

import 'package:flutter/material.dart';

class StreamingFade extends StatefulWidget {
  const StreamingFade({super.key, required this.text, required this.child});

  /// The text so far; each time it grows the edge fades in again.
  final String text;
  final Widget child;

  @override
  State<StreamingFade> createState() => _StreamingFadeState();
}

class _StreamingFadeState extends State<StreamingFade>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
    value: 1,
  );

  @visibleForTesting
  AnimationController get fadeForTest => _fade;

  @override
  void didUpdateWidget(StreamingFade old) {
    super.didUpdateWidget(old);
    if (widget.text.length > old.text.length) _fade.forward(from: 0.35);
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _fade,
    child: widget.child,
    builder: (context, child) => ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        // About the last line and a half fades; the rest stays solid.
        final edge = rect.height <= 0
            ? 0.0
            : (1 - 36 / rect.height).clamp(0.0, 1.0);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black,
            Colors.black,
            Colors.black.withValues(alpha: _fade.value),
          ],
          stops: [0, edge, 1],
        ).createShader(rect);
      },
      child: child,
    ),
  );
}
