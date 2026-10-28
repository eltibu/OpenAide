import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/voice/classic_call.dart';

class FakeHost implements ClassicCallHost {
  final sent = <(String, Uint8List?)>[];
  final talking = ValueNotifier(false);
  bool answering = false;
  String words = 'what time is it';
  Uint8List? picture;

  @override
  Future<String> transcribe(Uint8List wav) async {
    expect(String.fromCharCodes(wav.take(4)), 'RIFF');
    return words;
  }

  @override
  Future<void> send(String text, Uint8List? photo) async {
    sent.add((text, photo));
    answering = true;
  }

  @override
  bool get replying => answering;

  @override
  ValueListenable<bool> get speaking => talking;

  @override
  Future<void> stopSpeaking() async => talking.value = false;

  @override
  Future<Uint8List?> photo() async => picture;
}

/// 40 ms of 24 kHz audio at a steady loudness.
Map frame(double loud) {
  final data = ByteData(960 * 2);
  for (var i = 0; i < 960; i++) {
    data.setInt16(
      i * 2,
      ((i.isEven ? 1 : -1) * loud * 32767).round(),
      Endian.little,
    );
  }
  return {'type': 'input', 'pcm': data.buffer.asUint8List()};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/voice');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'start' ? 'started' : null,
        );
  });

  Future<(ClassicCall, StreamController, FakeHost)> started() async {
    final events = StreamController<dynamic>.broadcast();
    final host = FakeHost();
    final call = ClassicCall(host, method: channel, events: events.stream);
    await call.start();
    expect(call.phase, CallPhase.listening);
    return (call, events, host);
  }

  Future<void> speak(StreamController events, {int talk = 20}) async {
    for (var i = 0; i < 25; i++) {
      events.add(frame(0.001));
    }
    for (var i = 0; i < talk; i++) {
      events.add(frame(0.3));
    }
    for (var i = 0; i < 30; i++) {
      events.add(frame(0.001));
    }
    await pumpEventQueue();
  }

  test('a pause sends what was said, then the answer is read', () async {
    final (call, events, host) = await started();
    host.picture = Uint8List.fromList([1, 2, 3]);
    await speak(events);
    expect(host.sent.single.$1, 'what time is it');
    expect(host.sent.single.$2, [1, 2, 3]);
    expect(call.heard, 'what time is it');
    host.talking.value = true;
    expect(call.phase, CallPhase.speaking);
    host.answering = false;
    host.talking.value = false;
    expect(call.phase, CallPhase.listening);
    await call.end();
  });

  test('silence or no words sends nothing', () async {
    final (call, events, host) = await started();
    for (var i = 0; i < 80; i++) {
      events.add(frame(0.001));
    }
    await pumpEventQueue();
    expect(host.sent, isEmpty);
    host.words = '';
    await speak(events);
    expect(host.sent, isEmpty);
    expect(call.phase, CallPhase.listening);
    await call.end();
  });

  test('talking over the answer stops it; muted hears nothing', () async {
    final (call, events, host) = await started();
    await speak(events);
    host.talking.value = true;
    for (var i = 0; i < 10; i++) {
      events.add(frame(0.3));
    }
    await pumpEventQueue();
    expect(host.talking.value, isFalse);
    // Still talking: what's said now is the next turn.
    expect(call.phase, CallPhase.hearing);
    call.mute();
    await speak(events);
    expect(host.sent.length, 1);
    await call.end();
    expect(call.phase, CallPhase.ended);
  });

  test('the headset button stops the answer, then mutes', () async {
    final (call, events, host) = await started();
    await speak(events);
    host.talking.value = true;
    expect(call.phase, CallPhase.speaking);
    events.add({'type': 'button'});
    await pumpEventQueue();
    expect(host.talking.value, isFalse);
    expect(call.phase, CallPhase.listening);
    events.add({'type': 'button'});
    await pumpEventQueue();
    expect(call.muted, isTrue);
    await call.end();
  });
}
