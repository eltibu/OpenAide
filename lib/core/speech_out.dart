import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'platform_caps.dart';

/// Plays read-aloud audio files one at a time. On Android it is the app's
/// own player (MainActivity.kt, `nexus/speech`); everywhere else the
/// `audioplayers` plugin plays the same files.
abstract class SpeechOut {
  factory SpeechOut() =>
      PlatformCaps.nativeVoice ? _ChannelSpeech() : _PluginSpeech();

  /// A folder for the audio pieces.
  Future<String> dir();

  /// Plays [path] and finishes when it has been heard.
  Future<void> play(String path, {double rate = 1});

  Future<void> stop();
}

class _ChannelSpeech implements SpeechOut {
  static const _channel = MethodChannel('nexus/speech');

  @override
  Future<String> dir() async => (await _channel.invokeMethod<String>('dir'))!;

  @override
  Future<void> play(String path, {double rate = 1}) =>
      _channel.invokeMethod('play', {'path': path, 'rate': rate});

  @override
  Future<void> stop() => _channel.invokeMethod('stop');
}

class _PluginSpeech implements SpeechOut {
  AudioPlayer? _player;
  Completer<void>? _playing;

  @override
  Future<String> dir() async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/speech');
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<void> play(String path, {double rate = 1}) async {
    final player = _player ??= AudioPlayer()
      ..onPlayerComplete.listen((_) => _finish());
    _finish();
    final done = _playing = Completer<void>();
    await player.setPlaybackRate(rate);
    await player.play(DeviceFileSource(path));
    return done.future;
  }

  void _finish() {
    final playing = _playing;
    _playing = null;
    if (playing != null && !playing.isCompleted) playing.complete();
  }

  @override
  Future<void> stop() async {
    await _player?.stop();
    _finish();
  }
}
