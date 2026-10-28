/// The web's classic voice call, for servers without Realtime calls: you
/// talk, a pause sends what you said (turned into text by the server, with
/// a camera photo when the camera is on), the chat model answers, and the
/// answer is read aloud. Talking over it, or a tap, stops it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../studio/listen.dart' show Cutter, frameLevel, wavFile;

enum CallPhase { starting, listening, hearing, thinking, speaking, ended }

/// What the call needs from the app, so tests can stand in for it.
abstract class ClassicCallHost {
  /// The server's speech to text.
  Future<String> transcribe(Uint8List wav);

  /// Sends [text] (with [photo]) in the chat; the answer is read aloud.
  Future<void> send(String text, Uint8List? photo);

  /// True while the chat model is still answering.
  bool get replying;

  /// True while the answer is being read aloud.
  ValueListenable<bool> get speaking;

  /// Stops reading the answer aloud.
  Future<void> stopSpeaking();

  /// The camera's view now, when the camera is on.
  Future<Uint8List?> photo();
}

class ClassicCall extends ChangeNotifier {
  ClassicCall(this.host, {MethodChannel? method, Stream<dynamic>? events})
    : _method = method ?? const MethodChannel('nexus/voice'),
      _events =
          events ??
          const EventChannel('nexus/voice/events').receiveBroadcastStream();

  final ClassicCallHost host;
  final MethodChannel _method;
  final Stream<dynamic> _events;

  CallPhase phase = CallPhase.starting;
  bool muted = false;
  double level = 0;
  String? problem;

  /// What you said last, for the screen.
  String heard = '';

  StreamSubscription<dynamic>? _sub;
  Cutter _cutter = _newCutter();
  int _loud = 0;
  bool _sent = false;

  static Cutter _newCutter() => Cutter(
    shortest: const Duration(milliseconds: 500),
    pause: const Duration(milliseconds: 1100),
    longest: const Duration(seconds: 40),
  );

  Future<void> start() async {
    host.speaking.addListener(update);
    _sub = _events.listen(_onEvent);
    final status =
        await _method.invokeMethod<String>('start') ??
        'The microphone could not be started';
    if (status != 'started') {
      problem = status == 'denied'
          ? 'OpenAide needs the microphone for calls.'
          : status;
      await end();
      return;
    }
    if (phase == CallPhase.ended) return;
    await _method.invokeMethod('capture', {'enabled': true});
    if (phase != CallPhase.ended) _listen();
  }

  void _listen() {
    _cutter = _newCutter();
    _loud = 0;
    _sent = false;
    phase = CallPhase.listening;
    notifyListeners();
  }

  void _onEvent(dynamic e) {
    if (e is! Map || phase == CallPhase.ended) return;
    if (e['type'] == 'error') {
      problem = '${e['message']}';
      notifyListeners();
      return;
    }
    if (e['type'] == 'button') {
      // Headset button: stops the answer, or mutes and unmutes.
      phase == CallPhase.speaking ? unawaited(interrupt()) : mute();
      return;
    }
    if (e['type'] != 'input') return;
    final frame = e['pcm'] as Uint8List;
    level = muted ? 0 : frameLevel(frame);
    if (muted) return notifyListeners();
    switch (phase) {
      case CallPhase.listening || CallPhase.hearing:
        final piece = _cutter.add(frame);
        if (phase == CallPhase.listening && level > _cutter.threshold) {
          phase = CallPhase.hearing;
        }
        if (piece != null) unawaited(_turn(piece));
      case CallPhase.speaking:
        // Talking over the answer stops it; the echo of the answer itself
        // is quieter than that.
        _loud = level > 0.08 ? _loud + 1 : 0;
        if (_loud >= 8) unawaited(interrupt());
      default:
        break;
    }
    notifyListeners();
  }

  Future<void> _turn(Uint8List pcm) async {
    phase = CallPhase.thinking;
    notifyListeners();
    try {
      final text = await host.transcribe(wavFile(pcm));
      if (phase == CallPhase.ended) return;
      if (text.trim().isEmpty) return _listen();
      heard = text.trim();
      notifyListeners();
      await host.send(heard, await host.photo());
      _sent = true;
      update();
    } catch (e) {
      problem = '$e';
      if (phase != CallPhase.ended) _listen();
    }
  }

  /// Called when the chat or the speaker changes: the answer starts being
  /// read, or it's done and it's your turn again.
  void update() {
    if (!_sent || phase == CallPhase.ended) return;
    if (host.speaking.value) {
      if (phase != CallPhase.speaking) {
        phase = CallPhase.speaking;
        notifyListeners();
      }
    } else if (!host.replying) {
      _listen();
    }
  }

  /// Stops the answer and listens again.
  Future<void> interrupt() async {
    _sent = false;
    await host.stopSpeaking();
    if (phase != CallPhase.ended) _listen();
  }

  void mute() {
    muted = !muted;
    if (muted) _cutter = _newCutter();
    notifyListeners();
  }

  Future<void> end() async {
    if (phase == CallPhase.ended) return;
    phase = CallPhase.ended;
    host.speaking.removeListener(update);
    notifyListeners();
    await _sub?.cancel();
    try {
      await _method.invokeMethod('stop');
    } on MissingPluginException {
      // Not on a phone.
    }
    await host.stopSpeaking();
  }
}
