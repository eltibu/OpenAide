/// Speech to text for the Studio: the phone's microphone, cut into pieces
/// at pauses, each piece turned into text by the server's transcription
/// (the same speech-to-text Open WebUI uses).
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http_parser/http_parser.dart';

import '../../core/api/openwebui_client.dart';

const micRate = 24000;

/// 16-bit mono PCM as a WAV file.
Uint8List wavFile(List<int> pcm, {int rate = micRate}) {
  final out = BytesBuilder();
  final head = ByteData(44);
  void text(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      head.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  head.setUint32(4, 36 + pcm.length, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  head.setUint32(16, 16, Endian.little);
  head.setUint16(20, 1, Endian.little); // PCM
  head.setUint16(22, 1, Endian.little); // mono
  head.setUint32(24, rate, Endian.little);
  head.setUint32(28, rate * 2, Endian.little);
  head.setUint16(32, 2, Endian.little);
  head.setUint16(34, 16, Endian.little);
  text(36, 'data');
  head.setUint32(40, pcm.length, Endian.little);
  out
    ..add(head.buffer.asUint8List())
    ..add(pcm);
  return out.toBytes();
}

/// The server's speech to text.
Future<String> transcribe(
  OpenWebUiClient client,
  List<int> bytes,
  String filename, {
  String? language,
}) async {
  final ext = filename.split('.').last.toLowerCase();
  final type = switch (ext) {
    'wav' => MediaType('audio', 'wav'),
    'mp3' || 'mpga' || 'mpeg' => MediaType('audio', 'mpeg'),
    'm4a' => MediaType('audio', 'mp4'),
    'mp4' => MediaType('video', 'mp4'),
    'ogg' || 'oga' || 'opus' => MediaType('audio', 'ogg'),
    'webm' => MediaType('audio', 'webm'),
    'flac' => MediaType('audio', 'flac'),
    'aac' => MediaType('audio', 'aac'),
    '3gp' => MediaType('audio', '3gpp'),
    _ => MediaType('audio', ext),
  };
  final res = await client.sendFile(
    '/api/v1/audio/transcriptions',
    bytes,
    filename,
    contentType: type,
    fields: {'language': ?language},
  );
  return res is Map ? '${res['text'] ?? ''}'.trim() : '';
}

/// How loud a 16-bit frame is, 0 to 1.
double frameLevel(Uint8List pcm) {
  final data = ByteData.sublistView(pcm);
  var sum = 0.0;
  final n = pcm.length ~/ 2;
  for (var i = 0; i < n; i++) {
    final v = data.getInt16(i * 2, Endian.little) / 32768.0;
    sum += v * v;
  }
  return n == 0 ? 0 : math.sqrt(sum / n);
}

/// Where a recording is cut into pieces: after a pause once a piece is a
/// few seconds long, or at [longest]. Pieces with no speech are dropped
/// (speech to text tends to invent words for silence).
class Cutter {
  Cutter({
    this.shortest = const Duration(seconds: 4),
    this.longest = const Duration(seconds: 28),
    this.pause = const Duration(milliseconds: 700),
  });

  final Duration shortest;
  final Duration longest;
  final Duration pause;

  final _piece = BytesBuilder(copy: false);
  int _samples = 0;
  int _quietSamples = 0;
  int _speechSamples = 0;
  final _recent = <double>[];

  /// The level speech has to pass: above the room's own noise (the
  /// quietest moment of the last three seconds), and never so high that
  /// clear speech is missed.
  double get threshold {
    final floor = _recent.isEmpty ? 0.0 : _recent.reduce(math.min);
    return (floor * 2.5).clamp(0.012, 0.06);
  }

  Duration get length => Duration(microseconds: _samples * 1000000 ~/ micRate);

  /// Adds a frame; returns a finished piece (PCM) when one is cut.
  Uint8List? add(Uint8List frame) {
    final level = frameLevel(frame);
    _recent.add(level);
    if (_recent.length > 75) _recent.removeAt(0);
    final n = frame.length ~/ 2;
    _piece.add(frame);
    _samples += n;
    if (level > threshold) {
      _speechSamples += n;
      _quietSamples = 0;
    } else {
      _quietSamples += n;
    }
    final quiet = Duration(microseconds: _quietSamples * 1000000 ~/ micRate);
    if ((length >= shortest && quiet >= pause) || length >= longest) {
      return flush();
    }
    return null;
  }

  /// What is left, if it has speech in it.
  Uint8List? flush() {
    final pcm = _piece.takeBytes();
    final speech = _speechSamples;
    _samples = 0;
    _quietSamples = 0;
    _speechSamples = 0;
    // A quarter second of speech at least.
    return speech >= micRate ~/ 4 ? pcm : null;
  }
}

/// Listens until stopped, handing up text piece by piece, in order.
class SpeechListener {
  SpeechListener(this.client, {required this.onText, Cutter? cutter})
    : _cutter = cutter ?? Cutter();

  final OpenWebUiClient client;
  final Cutter _cutter;

  /// Each piece of text, in the order it was said.
  final void Function(String text) onText;

  static const _method = MethodChannel('nexus/voice');
  static const _events = EventChannel('nexus/voice/events');

  StreamSubscription<dynamic>? _sub;
  Future<void> _last = Future.value();
  int _waiting = 0;
  bool _paused = false;

  /// The microphone's level, for a meter.
  final level = StreamController<double>.broadcast();

  /// Pieces sent and not yet back.
  final waiting = StreamController<int>.broadcast();

  /// Problems with a piece or the microphone.
  final errors = StreamController<String>.broadcast();

  bool get paused => _paused;

  /// "started", "denied" or a problem.
  Future<String> start() async {
    _sub = _events.receiveBroadcastStream().listen((e) {
      if (e is! Map) return;
      if (e['type'] == 'error') errors.add('${e['message']}');
      if (e['type'] != 'input' || _paused) return;
      final frame = e['pcm'] as Uint8List;
      level.add(frameLevel(frame));
      final piece = _cutter.add(frame);
      if (piece != null) _send(piece);
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

  void pause(bool on) {
    _paused = on;
    if (on) {
      final piece = _cutter.flush();
      if (piece != null) _send(piece);
    }
  }

  void _send(Uint8List pcm) {
    final wav = wavFile(pcm);
    // Sent at once, handed up in order.
    final text = _transcribe(wav);
    waiting.add(++_waiting);
    _last = _last.then((_) async {
      final t = await text;
      waiting.add(--_waiting);
      if (t.isNotEmpty) onText(t);
    });
  }

  Future<String> _transcribe(Uint8List wav) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await transcribe(client, wav, 'speech.wav');
      } catch (e) {
        if (attempt >= 1) {
          errors.add('A part couldn\'t be turned into text: $e');
          return '';
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Stops listening; done when the last piece is back.
  Future<void> stop() async {
    await _method.invokeMethod('stop');
    await _sub?.cancel();
    _sub = null;
    final piece = _cutter.flush();
    if (piece != null) _send(piece);
    await _last;
    await level.close();
    await waiting.close();
    await errors.close();
  }

  /// Stops without waiting for text.
  Future<void> cancel() async {
    await _method.invokeMethod('stop');
    await _sub?.cancel();
    _sub = null;
  }
}
