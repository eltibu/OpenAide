/// Read aloud: with the toggle on, every reply is spoken as it is written,
/// in the server's text-to-speech voice, until the toggle is turned off.
/// The toggle is the web UI's "Auto-playback response" setting, kept on
/// the server.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/theme.dart';
import 'chat_controller.dart';

/// The settings key the web UI uses for "Auto-playback response".
const readAloudKey = 'responseAutoPlayback';

/// A reply's markdown as words to say: no code, links, tables or marks.
String speakable(String markdown) {
  var t = markdown
      .replaceAll(RegExp(r'<details[\s\S]*?(</details>|$)'), ' ')
      .replaceAll(RegExp(r'```[\s\S]*?(```|$)'), ' ')
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'https?://\S+'), '')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll(
        RegExp(r'^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$', multiLine: true),
        '',
      )
      .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*([-*+]|\d+[.)])\s+', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*>\s?', multiLine: true), '')
      .replaceAll(RegExp(r'\*\*|__|~~|[*`]'), '')
      .replaceAll(RegExp(r'[ \t]*\|[ \t]*'), ', ');
  t = t
      .split('\n')
      .map((l) => l.trim().replaceAll(RegExp(r'^,\s*|,\s*$'), ''))
      .where((l) => l.isNotEmpty)
      .join('\n');
  return t.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
}

/// How much of [text], from [from], is ready to be said while the reply is
/// still being written: up to the last finished sentence or line, and never
/// into a code block that hasn't closed yet.
int readyUpTo(String text, int from) {
  var end = from;
  for (final m in RegExp(r'[.!?…:;](?=\s)|\n').allMatches(text, from)) {
    end = m.end;
  }
  final fences = RegExp(r'```').allMatches(text.substring(0, end)).toList();
  if (fences.length.isOdd) {
    end = fences.last.start < from ? from : fences.last.start;
  }
  return end;
}

/// Says text, piece after piece, getting the next piece ready while one
/// plays.
class ReadAloud {
  ReadAloud(this.client);

  final OpenWebUiClient client;

  /// The voice to ask for; the server's own when null.
  String? voice;

  static const _channel = MethodChannel('nexus/speech');

  final _queue = <String>[];
  int _gen = 0;
  bool _running = false;
  int _piece = 0;

  /// True while something is being said.
  final speaking = ValueNotifier<bool>(false);

  /// Why speaking failed, for the screen to say once.
  final errors = StreamController<String>.broadcast();

  void say(String text) {
    final t = speakable(text);
    if (t.isEmpty) return;
    _queue.add(t);
    if (!_running) unawaited(_run(_gen));
  }

  /// Stops speaking and forgets what was waiting.
  Future<void> stop() async {
    _gen++;
    _queue.clear();
    _running = false;
    speaking.value = false;
    try {
      await _channel.invokeMethod('stop');
    } on MissingPluginException {
      // Not on a phone.
    }
  }

  String _take() {
    var out = '';
    while (_queue.isNotEmpty &&
        (out.isEmpty || out.length + _queue.first.length < 600)) {
      out = '$out\n${_queue.removeAt(0)}'.trim();
    }
    return out;
  }

  Future<List<int>> _fetch(String text) => client.postForBytes(
    '/api/v1/audio/speech',
    {'input': text, if (voice != null && voice!.isNotEmpty) 'voice': voice},
  );

  Future<void> _run(int gen) async {
    _running = true;
    speaking.value = true;
    try {
      String? dir;
      Future<List<int>>? next = _queue.isEmpty ? null : _fetch(_take());
      while (next != null && gen == _gen) {
        List<int> audio;
        try {
          audio = await next;
        } catch (e) {
          if (gen == _gen) errors.add('$e');
          await stop();
          return;
        }
        if (gen != _gen) return;
        // The next piece is fetched while this one plays.
        next = _queue.isEmpty ? null : _fetch(_take());
        if (audio.isNotEmpty) {
          dir ??= await _channel.invokeMethod<String>('dir');
          final wav =
              audio.length > 4 && String.fromCharCodes(audio.take(4)) == 'RIFF';
          final file = File('$dir/piece${_piece++ % 3}.${wav ? 'wav' : 'mp3'}');
          await file.writeAsBytes(audio, flush: true);
          if (gen != _gen) return;
          await _channel.invokeMethod('play', {'path': file.path});
        }
        if (next == null && _queue.isNotEmpty && gen == _gen) {
          next = _fetch(_take());
        }
      }
    } on MissingPluginException {
      // Not on a phone.
    } finally {
      if (gen == _gen) {
        _running = false;
        speaking.value = false;
      }
    }
  }
}

final readAloudProvider = Provider<ReadAloud>((ref) {
  final r = ReadAloud(ref.watch(clientProvider));
  ref.onDispose(() {
    unawaited(r.stop());
    unawaited(r.errors.close());
  });
  return r;
});

/// The toggle, as saved on the server.
class ReadAloudToggle extends Notifier<bool> {
  @override
  bool build() {
    final ui = ref.watch(userSettingsProvider).value?['ui'];
    return ui is Map && ui[readAloudKey] == true;
  }

  Future<void> set(bool on) async {
    state = on;
    if (!on) await ref.read(readAloudProvider).stop();
    try {
      await ref
          .read(clientProvider)
          .send(
            'POST',
            '/api/v1/users/user/settings/update',
            body: {
              'ui': {readAloudKey: on},
            },
          );
    } catch (_) {
      // Stays as set on this phone until the settings load again.
    }
  }
}

final readAloudOnProvider = NotifierProvider<ReadAloudToggle, bool>(
  ReadAloudToggle.new,
);

/// The voice the web would use: yours from Settings > Audio, else the
/// server's.
String? speechVoice(
  Map<String, dynamic>? settings,
  Map<String, dynamic>? config,
) {
  String? pick(Object? audio) {
    final tts = audio is Map ? audio['tts'] : null;
    final v = tts is Map ? tts['voice'] : null;
    return v is String && v.isNotEmpty ? v : null;
  }

  return pick(settings?['audio']) ?? pick(config?['audio']);
}

/// The read-aloud toggle for the chat's top bar: on, every reply is spoken
/// until it is turned off.
class ReadAloudButton extends ConsumerStatefulWidget {
  const ReadAloudButton({super.key});

  @override
  ConsumerState<ReadAloudButton> createState() => _ReadAloudButtonState();
}

class _ReadAloudButtonState extends ConsumerState<ReadAloudButton> {
  StreamSubscription<String>? _errors;

  @override
  void initState() {
    super.initState();
    _errors = ref.read(readAloudProvider).errors.stream.listen((e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.contains('404') || e.toLowerCase().contains('not found')
                ? 'Read aloud needs text to speech turned on in the '
                      'server\'s Admin settings (Audio).'
                : 'Couldn\'t read the reply aloud: $e',
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _errors?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = ref.watch(readAloudOnProvider);
    final speaker = ref.watch(readAloudProvider);
    return ValueListenableBuilder<bool>(
      valueListenable: speaker.speaking,
      builder: (context, speaking, _) => IconButton(
        tooltip: on ? 'Read aloud is on' : 'Read replies aloud',
        isSelected: on,
        color: on ? NexusColors.accent : null,
        icon: Icon(
          !on
              ? Icons.volume_off_outlined
              : speaking
              ? Icons.graphic_eq
              : Icons.volume_up_outlined,
        ),
        onPressed: () {
          ref.read(readAloudOnProvider.notifier).set(!on);
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                duration: const Duration(seconds: 2),
                content: Text(
                  on
                      ? 'Read aloud off'
                      : 'Read aloud on: Nexus speaks every reply until you '
                            'turn it off',
                ),
              ),
            );
        },
      ),
    );
  }
}
