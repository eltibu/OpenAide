import 'dart:async';

import 'package:flutter/services.dart';

/// The phone's microphone and speaker during a call: 24 kHz mono PCM16 both
/// ways. Events are maps, as the web UI's audio worklet posts them:
/// `input` (a 40 ms mic frame in `pcm`), `playback` (levels and how much is
/// still queued), `error`.
abstract class CallAudio {
  Stream<Map<String, dynamic>> get events;

  /// "started", "denied" (no microphone permission) or an error message.
  Future<String> start();
  Future<void> stop();

  /// Sends mic frames while on (off while muted or connecting).
  Future<void> capture(bool enabled);

  /// Holds playback while the person may be talking over the reply.
  Future<void> pause(bool paused);

  /// Queues reply audio for playback.
  Future<void> play(
    Uint8List pcm, {
    required String responseId,
    required String itemId,
    required int contentIndex,
  });

  /// No more audio is coming for [responseId]: play what's queued.
  Future<void> done(String responseId);

  /// Drops everything queued and reports how much of each item was heard:
  /// `{id, rendered: [{response_id, item_id, content_index, samples}],
  /// latency_ms}`.
  Future<Map<String, dynamic>> clear(int id);
}

/// [CallAudio] on Android (VoiceAudio.kt).
class AndroidCallAudio implements CallAudio {
  static const _method = MethodChannel('nexus/voice');
  static const _events = EventChannel('nexus/voice/events');

  @override
  late final Stream<Map<String, dynamic>> events = _events
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => (e as Map).cast<String, dynamic>());

  @override
  Future<String> start() async =>
      await _method.invokeMethod<String>('start') ?? 'Could not start audio';

  @override
  Future<void> stop() => _method.invokeMethod('stop');

  @override
  Future<void> capture(bool enabled) =>
      _method.invokeMethod('capture', {'enabled': enabled});

  @override
  Future<void> pause(bool paused) =>
      _method.invokeMethod('pause', {'paused': paused});

  @override
  Future<void> play(
    Uint8List pcm, {
    required String responseId,
    required String itemId,
    required int contentIndex,
  }) => _method.invokeMethod('audio', {
    'pcm': pcm,
    'response_id': responseId,
    'item_id': itemId,
    'content_index': contentIndex,
  });

  @override
  Future<void> done(String responseId) =>
      _method.invokeMethod('done', {'response_id': responseId});

  @override
  Future<Map<String, dynamic>> clear(int id) async {
    final res = await _method.invokeMethod<Map>('clear', {'id': id});
    return res?.cast<String, dynamic>() ?? {'id': id, 'rendered': const []};
  }
}
