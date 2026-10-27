// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';

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

  test(
    'a temporary chat is answered but not saved, until saved',
    () async {
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
        ..selectModel(models.first.id)
        ..newChat(temporary: true);
      Future<void> settle() async {
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (!container.read(chatControllerProvider).streaming) return;
        }
      }

      final before = (await client.chats()).length;
      await controller.send('Secret plan one');
      await settle();
      await controller.send('Secret plan two');
      await settle();
      var state = container.read(chatControllerProvider);
      expect(state.error, isNull);
      expect(state.temporary, isTrue);
      expect(state.messages, hasLength(4));
      expect(state.messages.last.content, contains('Secret plan two'));
      expect(state.chat!.id, isEmpty);
      expect((await client.chats()).length, before);

      await controller.saveTemporary();
      state = container.read(chatControllerProvider);
      expect(state.temporary, isFalse);
      expect(state.chat!.id, isNotEmpty);
      expect(state.chat!.title, 'Secret plan one');
      expect(state.messages, hasLength(4));
      final saved = await client.chat(state.chat!.id);
      expect(saved.thread.last.content, contains('Secret plan two'));
      await client.deleteChat(state.chat!.id);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
