// Runs against a real Open WebUI server; see server_sync_test.dart. Its
// speech to text must answer (the test's fake one says "hello from a voice
// note").
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/studio/listen.dart';

class _Session extends SessionNotifier {
  _Session(this.session);
  final Session session;
  @override
  Future<Session?> build() async => session;
}

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  TestWidgetsFlutterBinding.ensureInitialized();

  test('a voice note is sent with its words and plays back', () async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(
          () => _Session(Session(serverUrl: url, token: client.token!)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    final models = await container.read(modelsProvider.future);
    final controller = container.read(chatControllerProvider.notifier)
      ..selectModel(models.first.id);
    String? chatId;
    try {
      // A second of quiet, as the phone records it.
      final wav = wavFile(List<int>.filled(micRate * 2, 0));
      await controller.sendVoiceNote(wav);
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!container.read(chatControllerProvider).streaming) break;
      }
      final state = container.read(chatControllerProvider);
      chatId = state.chat!.id;
      expect(state.error, isNull);
      expect(state.attachments, isEmpty);

      final saved = await client.chat(chatId);
      final user = saved.thread.firstWhere((m) => m.role == 'user');
      expect(user.content, 'hello from a voice note');
      final note = user.attachments.single;
      expect(note.isAudio, isTrue);
      expect(saved.thread.last.content, contains('hello from a voice note'));

      // The recording plays back from the server.
      final res = await http.get(
        client.fileContentUri(note.fileId!),
        headers: client.authHeaders,
      );
      expect(res.statusCode, 200);
      expect(res.bodyBytes.length, wav.length);
    } finally {
      if (chatId != null) await client.deleteChat(chatId);
    }
  }, skip: skip);
}
