import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'platform_caps.dart';

/// The microphone, for dictation, voice notes, Listen mode and the classic
/// voice call. Same calls and events as Android's own audio code
/// (VoiceAudio.kt, on `nexus/voice`): `start` answers "started", "denied"
/// or a problem; `capture` turns mic frames on and off; events are maps
/// with `type: input` and 24 kHz mono PCM16 in `pcm`.
///
/// On Android it is that channel. Everywhere else the `record` plugin
/// captures the same frames, so the screens above work unchanged.
abstract class Mic {
  factory Mic() => PlatformCaps.nativeVoice ? _ChannelMic() : _RecordMic();

  /// A given channel and event stream, e.g. fakes in tests.
  factory Mic.fromChannel(MethodChannel method, Stream<dynamic> events) =>
      _ChannelMic(method, events);

  Stream<dynamic> get events;

  /// "started", "denied" or a problem to show.
  Future<String> start({bool record = false});

  Future<void> capture(bool enabled);

  Future<void> stop();
}

class _ChannelMic implements Mic {
  _ChannelMic([MethodChannel? method, Stream<dynamic>? events])
    : _method = method ?? const MethodChannel('nexus/voice'),
      _events = events;

  final MethodChannel _method;
  final Stream<dynamic>? _events;

  @override
  Stream<dynamic> get events =>
      _events ??
      const EventChannel('nexus/voice/events').receiveBroadcastStream();

  @override
  Future<String> start({bool record = false}) async =>
      await _method.invokeMethod<String>(
        'start',
        record ? {'record': true} : null,
      ) ??
      'The microphone could not be started';

  @override
  Future<void> capture(bool enabled) =>
      _method.invokeMethod('capture', {'enabled': enabled});

  @override
  Future<void> stop() => _method.invokeMethod('stop');
}

class _RecordMic implements Mic {
  static const _rate = 24000;

  /// 40 ms frames, as the Android side sends them.
  static const _frameBytes = _rate * 2 * 40 ~/ 1000;

  AudioRecorder? _recorder;
  final _out = StreamController<dynamic>.broadcast();
  final _pending = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _sub;
  bool _capturing = false;

  @override
  Stream<dynamic> get events => _out.stream;

  @override
  Future<String> start({bool record = false}) async {
    try {
      final recorder = _recorder ??= AudioRecorder();
      if (!await recorder.hasPermission()) return 'denied';
      final stream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _rate,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
        ),
      );
      _sub = stream.listen(
        _onAudio,
        onError: (Object e) {
          _out.add({'type': 'error', 'message': '$e'});
        },
      );
      return 'started';
    } catch (e) {
      return 'The microphone could not be started: $e';
    }
  }

  void _onAudio(Uint8List bytes) {
    if (!_capturing) return;
    _pending.add(bytes);
    if (_pending.length < _frameBytes) return;
    final all = _pending.takeBytes();
    var at = 0;
    for (; at + _frameBytes <= all.length; at += _frameBytes) {
      _out.add({
        'type': 'input',
        'pcm': Uint8List.sublistView(all, at, at + _frameBytes),
      });
    }
    if (at < all.length) _pending.add(Uint8List.sublistView(all, at));
  }

  @override
  Future<void> capture(bool enabled) async {
    _capturing = enabled;
    if (!enabled) _pending.clear();
  }

  @override
  Future<void> stop() async {
    _capturing = false;
    _pending.clear();
    await _sub?.cancel();
    _sub = null;
    final recorder = _recorder;
    _recorder = null;
    try {
      await recorder?.stop();
      await recorder?.dispose();
    } catch (_) {}
  }
}
