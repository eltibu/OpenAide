/// Voice notes in the chat box: record, then send the recording (the model
/// reads the server's transcription of it) or drop the words into the text
/// box to edit first. Separate from a live call.
library;

import '../phone/phone_action_ui.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/auth/session.dart';
import '../studio/listen.dart';
import 'chat_controller.dart';
import 'speech_prefs.dart';
import '../../core/i18n/app_strings.dart';

/// The whole recording, kept in memory until it is sent.
class VoiceNoteRecorder {
  static const _method = MethodChannel('nexus/voice');
  static const _events = EventChannel('nexus/voice/events');

  final _pcm = BytesBuilder(copy: false);
  StreamSubscription<dynamic>? _sub;
  int _samples = 0;

  /// The microphone's level, 0 to 1.
  final level = StreamController<double>.broadcast();

  Duration get length => Duration(microseconds: _samples * 1000000 ~/ micRate);

  /// "started", "denied" or a problem.
  Future<String> start() async {
    _sub = _events.receiveBroadcastStream().listen((e) {
      if (e is! Map || e['type'] != 'input') return;
      final frame = e['pcm'] as Uint8List;
      _pcm.add(frame);
      _samples += frame.length ~/ 2;
      level.add(frameLevel(frame));
    });
    final status =
        await _method.invokeMethod<String>('start', {'record': true}) ??
        'The microphone could not be started';
    if (status != 'started') {
      await _sub?.cancel();
      return status;
    }
    await _method.invokeMethod('capture', {'enabled': true});
    return status;
  }

  /// Stops and returns the recording as a WAV file.
  Future<Uint8List> stop() async {
    await _close();
    return wavFile(_pcm.takeBytes());
  }

  Future<void> cancel() async {
    await _close();
    _pcm.clear();
  }

  Future<void> _close() async {
    try {
      await _method.invokeMethod('stop');
    } catch (_) {}
    await _sub?.cancel();
    _sub = null;
    await level.close();
  }
}

String clock(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Takes the composer's place while a voice note is recorded.
class VoiceNoteBar extends ConsumerStatefulWidget {
  const VoiceNoteBar({super.key, required this.onDone, required this.onWords});

  /// Recording finished or cancelled; the composer comes back.
  final VoidCallback onDone;

  /// The words of the note, for the text box instead of sending.
  final ValueChanged<String> onWords;

  @override
  ConsumerState<VoiceNoteBar> createState() => _VoiceNoteBarState();
}

class _VoiceNoteBarState extends ConsumerState<VoiceNoteBar> {
  final _recorder = VoiceNoteRecorder();
  final _levels = List<double>.filled(32, 0, growable: true);
  StreamSubscription<double>? _sub;
  Timer? _tick;
  bool _working = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    _sub = _recorder.level.stream.listen((l) {
      _levels
        ..removeAt(0)
        ..add(l);
    });
    final status = await _recorder.start();
    if (!mounted) return;
    if (status != 'started') {
      setState(
        () => _problem = status == 'denied'
            ? 'OpenAide needs the microphone for voice notes. Allow it in '
                  'Android settings.'
            : status,
      );
      return;
    }
    HapticFeedback.lightImpact();
    _tick = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    if (!_working) unawaited(_recorder.cancel());
    super.dispose();
  }

  Future<void> _cancel() async {
    _working = true;
    _tick?.cancel();
    await _recorder.cancel();
    widget.onDone();
  }

  Future<Uint8List?> _finish() async {
    if (_recorder.length < const Duration(milliseconds: 600)) {
      await _cancel();
      return null;
    }
    _working = true;
    _tick?.cancel();
    return _recorder.stop();
  }

  Future<void> _send() async {
    final wav = await _finish();
    if (wav == null) return;
    widget.onDone();
    unawaited(ref.read(chatControllerProvider.notifier).sendVoiceNote(wav));
  }

  Future<void> _toText() async {
    final wav = await _finish();
    if (wav == null) return;
    setState(() => _problem = null);
    try {
      final settings = ref.read(userSettingsProvider).value;
      final text = await transcribe(
        ref.read(clientProvider),
        wav,
        'dictation.wav',
        language: speechLanguage(settings),
      );
      // Settings > Audio can send the words straight away, as on the web.
      if (text.isNotEmpty && speechAutoSend(settings)) {
        if (mounted && await tryPhoneAction(context, ref, text) != null) {
          widget.onDone();
          return;
        }
        unawaited(ref.read(chatControllerProvider.notifier).send(text));
      } else if (text.isNotEmpty) {
        widget.onWords(text);
      }
      widget.onDone();
    } catch (e) {
      if (mounted) setState(() => _problem = "Couldn't turn it into text: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_problem != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(_problem!, style: TextStyle(color: scheme.error)),
            ),
            IconButton(
              tooltip: tr('Close'),
              icon: const Icon(Icons.close),
              onPressed: widget.onDone,
            ),
          ],
        ),
      );
    }
    final busy = _working;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
      child: Row(
        children: [
          IconButton(
            tooltip: tr('Delete the recording'),
            icon: const Icon(Icons.delete_outline),
            onPressed: busy ? null : _cancel,
          ),
          Icon(Icons.fiber_manual_record, color: scheme.error, size: 14),
          const SizedBox(width: 6),
          Text(
            clock(_recorder.length),
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 28,
              child: busy
                  ? const Center(child: LinearProgressIndicator())
                  : CustomPaint(
                      painter: _Meter(List.of(_levels), scheme.primary),
                    ),
            ),
          ),
          IconButton(
            tooltip: tr('Put the words in the text box instead'),
            icon: const Icon(Icons.short_text),
            onPressed: busy ? null : _toText,
          ),
          IconButton.filled(
            tooltip: tr('Send voice note'),
            icon: const Icon(Icons.arrow_upward),
            onPressed: busy ? null : _send,
          ),
        ],
      ),
    );
  }
}

class _Meter extends CustomPainter {
  _Meter(this.levels, this.color);
  final List<double> levels;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final step = size.width / levels.length;
    for (var i = 0; i < levels.length; i++) {
      final h = (levels[i] * 6).clamp(0.08, 1.0) * size.height;
      final x = step * i + step / 2;
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Meter old) => true;
}

/// A voice note or other sound on a message: play, pause, and how far in.
class AudioTile extends StatefulWidget {
  const AudioTile({
    super.key,
    required this.uri,
    required this.headers,
    required this.name,
  });
  final Uri uri;
  final Map<String, String> headers;
  final String name;

  @override
  State<AudioTile> createState() => _AudioTileState();
}

class _AudioTileState extends State<AudioTile> {
  VideoPlayerController? _player;
  bool _loading = false;
  String? _problem;

  Future<void> _toggle() async {
    var p = _player;
    if (p == null) {
      setState(() => _loading = true);
      p = VideoPlayerController.networkUrl(
        widget.uri,
        httpHeaders: widget.headers,
      );
      try {
        await p.initialize();
      } catch (e) {
        await p.dispose();
        if (mounted) {
          setState(() {
            _loading = false;
            _problem = "Couldn't play it";
          });
        }
        return;
      }
      if (!mounted) {
        await p.dispose();
        return;
      }
      p.addListener(() => mounted ? setState(() {}) : null);
      setState(() {
        _player = p;
        _loading = false;
      });
    }
    final v = p.value;
    if (v.isPlaying) {
      await p.pause();
    } else {
      if (v.duration > Duration.zero && v.position >= v.duration) {
        await p.seekTo(Duration.zero);
      }
      await p.play();
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = _player?.value;
    final total = v?.duration ?? Duration.zero;
    final at = v?.position ?? Duration.zero;
    final playing = v?.isPlaying ?? false;
    return Container(
      width: 240,
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          _loading
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  tooltip: playing ? 'Pause' : 'Play',
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  onPressed: _problem == null ? _toggle : null,
                ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: total > Duration.zero
                      ? (at.inMilliseconds / total.inMilliseconds).clamp(0, 1)
                      : 0,
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(2),
                ),
                const SizedBox(height: 4),
                Text(
                  _problem ??
                      (total > Duration.zero
                          ? '${clock(at)} / ${clock(total)}'
                          : 'Voice note'),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
