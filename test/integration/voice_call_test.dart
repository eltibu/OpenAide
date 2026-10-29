// Runs against a real Open WebUI server with Realtime calls on; see
// server_sync_test.dart. The voice provider behind it may be a fake that
// "hears" a request after half a second of audio.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/voice/call_audio.dart';
import 'package:nexus_assistant/features/voice/call_screen.dart';
import 'package:nexus_assistant/features/voice/realtime_call.dart';

class _Session extends SessionNotifier {
  _Session(this.session);
  final Session session;
  @override
  Future<Session?> build() async => session;
}

/// Microphone and speaker stand-ins: silence in, played audio counted.
class _FakeAudio implements CallAudio {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  bool capturing = false;
  int played = 0;
  Timer? _mic;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<String> start() async {
    _mic = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (capturing) _events.add({'type': 'input', 'pcm': Uint8List(1920)});
      _events.add({
        'type': 'playback',
        'clearId': 0,
        'playbackActive': false,
        'queued': 0,
        'received': played,
        'inputLevel': 0.0,
        'outputLevel': 0.0,
      });
    });
    return 'started';
  }

  @override
  Future<void> stop() async => _mic?.cancel();
  @override
  Future<void> capture(bool enabled) async => capturing = enabled;
  @override
  Future<void> pause(bool paused) async {}
  @override
  Future<void> play(
    Uint8List pcm, {
    required String responseId,
    required String itemId,
    required int contentIndex,
  }) async => played += pcm.length ~/ 2;
  @override
  Future<void> done(String responseId) async {}
  @override
  Future<Map<String, dynamic>> clear(int id) async => {
    'id': id,
    'rendered': const [],
    'latency_ms': 0,
  };
}

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test(
    'a spoken request is saved, answered by the chat model and spoken',
    () async {
      final client = OpenWebUiClient(baseUrl: url!);
      await client.signIn(email!, password!);
      final config = await client.config();
      if ((config['audio'] as Map?)?['realtime']?['enabled'] != true) {
        markTestSkipped('Realtime calls are off on this server');
        return;
      }
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(
            () => _Session(Session(serverUrl: url, token: client.token!)),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.future);
      await container.read(serverConfigProvider.future);
      final models = await container.read(modelsProvider.future);
      container.read(chatControllerProvider.notifier)
        ..selectModel(models.first.id)
        ..voiceCall = true;

      final errors = <String>[];
      final audio = _FakeAudio();
      final call = RealtimeCall(
        host: ChatCallHost(container.read, errors.add),
        audio: audio,
        baseUrl: url,
      );
      container.listen(chatControllerProvider, (_, _) => call.update());
      String? chatId;
      try {
        await call.connect(client.token!);
        // Wait for: transcript saved, chat model answer, answer spoken.
        for (var i = 0; i < 120 && audio.played == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(errors, isEmpty);
        expect(audio.played, greaterThan(0));
        // Give the spoken transcript time to be saved.
        await Future<void>.delayed(const Duration(seconds: 1));
        chatId = container.read(chatControllerProvider).chat?.id;
        expect(chatId, isNotNull);

        final saved = await client.chat(chatId!);
        final thread = saved.thread;
        final user = thread.firstWhere((m) => m.role == 'user');
        expect(user.content, 'hello from the phone');
        expect((user.extra['meta'] as Map)['voice'], isA<Map>());
        final answer = thread.firstWhere((m) => m.role == 'assistant');
        expect(answer.content, contains('You said'));
        final voice = (answer.extra['meta'] as Map)['voice'] as Map;
        expect(
          (voice['speech'] as List).first['transcript'],
          contains('Spoken'),
        );
      } finally {
        call.dispose();
        if (chatId != null) await client.deleteChat(chatId);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
