// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/notes/notes_api.dart';

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

  test('a note and a past chat go with a message', () async {
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
    final notes = NotesApi(client);
    final note = await notes.create('Packing list', 'Tent, stove, rope');
    final chats = <String>[];
    Future<void> settle() async {
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!container.read(chatControllerProvider).streaming) return;
      }
    }

    try {
      await controller.send('First chat');
      await settle();
      final past = container.read(chatControllerProvider).chat!;
      chats.add(past.id);

      controller
        ..newChat()
        ..attachReference({
          'type': 'note',
          'id': note.id,
          'name': note.title,
          'status': 'uploaded',
        })
        ..attachReference({
          'type': 'chat',
          'id': past.id,
          'name': past.title,
          'status': 'uploaded',
        })
        // The same one twice is added once.
        ..attachReference({
          'type': 'chat',
          'id': past.id,
          'name': past.title,
          'status': 'uploaded',
        });
      expect(container.read(chatControllerProvider).attachments, hasLength(2));
      await controller.send('What should I pack?');
      await settle();
      final state = container.read(chatControllerProvider);
      chats.add(state.chat!.id);
      expect(state.error, isNull);
      final saved = await client.chat(state.chat!.id);
      final user = saved.thread.first;
      expect(user.attachments.map((a) => a.type), ['note', 'chat']);
      expect(saved.thread.last.content, isNotEmpty);
      expect(saved.thread.last.error, isNull);
    } finally {
      for (final id in chats) {
        await client.deleteChat(id);
      }
      await notes.delete(note.id);
    }
  }, skip: skip);
}
