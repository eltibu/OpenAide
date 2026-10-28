/// The classic call screen: the circle, what you said, the camera (front or
/// back, a photo going with each thing you say), mute and hang up.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../chat/chat_controller.dart';
import '../chat/read_aloud.dart';
import '../studio/listen.dart' as listen;
import 'classic_call.dart';

class _Host implements ClassicCallHost {
  _Host(this.ref, this.camera) : _speaker = ref.read(readAloudProvider);
  final WidgetRef ref;
  final CameraController? Function() camera;

  /// Kept, so the call can still be quieted as the screen closes.
  final ReadAloud _speaker;

  ChatController get _chat => ref.read(chatControllerProvider.notifier);

  @override
  Future<String> transcribe(Uint8List wav) =>
      listen.transcribe(ref.read(clientProvider), wav, 'call.wav');

  @override
  Future<void> send(String text, Uint8List? photo) async {
    if (photo != null) {
      await _chat.attach(photo, 'camera.jpg', mimeType: 'image/jpeg');
    }
    await _chat.send(text);
  }

  @override
  bool get replying => ref.read(chatControllerProvider).streaming;

  @override
  ValueListenable<bool> get speaking => _speaker.speaking;

  @override
  Future<void> stopSpeaking() => _speaker.stop();

  @override
  Future<Uint8List?> photo() async {
    final c = camera();
    if (c == null || !c.value.isInitialized) return null;
    try {
      return await (await c.takePicture()).readAsBytes();
    } catch (_) {
      return null;
    }
  }
}

class ClassicCallView extends ConsumerStatefulWidget {
  const ClassicCallView({super.key});

  @override
  ConsumerState<ClassicCallView> createState() => _ClassicCallViewState();
}

class _ClassicCallViewState extends ConsumerState<ClassicCallView> {
  late final ClassicCall _call = ClassicCall(_Host(ref, () => _camera));
  late final ChatController _controller;
  CameraController? _camera;
  List<CameraDescription> _cameras = const [];
  int _which = 0;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(chatControllerProvider.notifier)
      ..voiceCall = true
      ..classicCall = true;
    unawaited(_call.start());
  }

  @override
  void dispose() {
    _controller
      ..voiceCall = false
      ..classicCall = false;
    unawaited(_call.end().whenComplete(_call.dispose));
    unawaited(_camera?.dispose());
    super.dispose();
  }

  Future<void> _startCamera([int? which]) async {
    try {
      if (_cameras.isEmpty) _cameras = await availableCameras();
      if (_cameras.isEmpty) throw StateError('No camera on this phone');
      _which = (which ?? _which) % _cameras.length;
      final old = _camera;
      final next = CameraController(
        _cameras[_which],
        ResolutionPreset.medium,
        enableAudio: false,
      );
      setState(() => _camera = next);
      await old?.dispose();
      await next.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't start the camera: $e")),
        );
        await _stopCamera();
      }
    }
  }

  Future<void> _stopCamera() async {
    final old = _camera;
    setState(() => _camera = null);
    await old?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Every change in the chat may be the end of the answer.
    ref.listen(chatControllerProvider, (_, _) => _call.update());
    final model = ref
        .watch(modelsProvider)
        .value
        ?.where((m) => m.id == ref.watch(chatControllerProvider).modelId)
        .firstOrNull;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _call,
          builder: (context, _) {
            final call = _call;
            final camera = _camera;
            final status = switch (call.phase) {
              CallPhase.starting => 'Starting…',
              _ when call.muted => 'Muted',
              CallPhase.listening => 'Listening',
              CallPhase.hearing => 'Listening…',
              CallPhase.thinking => 'Thinking…',
              CallPhase.speaking => 'Speaking — tap to interrupt',
              CallPhase.ended => 'Call ended',
            };
            final level =
                (call.phase == CallPhase.speaking
                        ? 0.4
                        : math.min(call.level * 6, 1.0))
                    .toDouble();
            return Column(
              children: [
                const SizedBox(height: 24),
                Text(
                  model?.name ?? 'Voice call',
                  style: text.titleLarge?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(
                  status,
                  style: text.bodyMedium?.copyWith(color: Colors.white70),
                ),
                Expanded(
                  child: Center(
                    child: GestureDetector(
                      onTap: call.phase == CallPhase.speaking
                          ? call.interrupt
                          : null,
                      child: camera != null && camera.value.isInitialized
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: AspectRatio(
                                aspectRatio: 1 / camera.value.aspectRatio,
                                child: CameraPreview(camera),
                              ),
                            )
                          : AnimatedContainer(
                              duration: const Duration(milliseconds: 120),
                              width: 160 + 80 * level,
                              height: 160 + 80 * level,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [
                                    call.phase == CallPhase.speaking
                                        ? Colors.lightBlueAccent
                                        : Colors.white,
                                    call.phase == CallPhase.thinking
                                        ? Colors.deepPurple
                                        : Colors.blueGrey.shade800,
                                  ],
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
                if (call.heard.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      call.heard,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(color: Colors.white60),
                    ),
                  ),
                if (call.problem != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 8,
                    ),
                    child: Text(
                      call.problem!,
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(
                        color: Colors.orangeAccent,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      if (camera == null)
                        IconButton.filledTonal(
                          iconSize: 28,
                          tooltip: 'Camera',
                          onPressed: _startCamera,
                          icon: const Icon(Icons.videocam_outlined),
                        )
                      else ...[
                        IconButton.filledTonal(
                          iconSize: 28,
                          tooltip: 'Stop camera',
                          onPressed: _stopCamera,
                          icon: const Icon(Icons.videocam_off_outlined),
                        ),
                        if (_cameras.length > 1)
                          IconButton.filledTonal(
                            iconSize: 28,
                            tooltip: 'Switch camera',
                            onPressed: () => _startCamera(_which + 1),
                            icon: const Icon(Icons.cameraswitch_outlined),
                          ),
                      ],
                      IconButton.filledTonal(
                        iconSize: 28,
                        tooltip: call.muted ? 'Unmute' : 'Mute',
                        onPressed: call.mute,
                        icon: Icon(call.muted ? Icons.mic_off : Icons.mic),
                      ),
                      IconButton.filled(
                        iconSize: 28,
                        tooltip: 'Hang up',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.red,
                        ),
                        onPressed: () {
                          unawaited(_call.end());
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.call_end),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
