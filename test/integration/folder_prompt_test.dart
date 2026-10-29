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
    'a folder\'s system prompt reaches its chats, temporary ones too',
    () async {
      HttpOverrides.global = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null,
          );
      final client = OpenWebUiClient(baseUrl: url!);
      await client.signIn(email!, password!);
      final folder = await client.send(
        'POST',
        '/api/v1/folders/',
        body: {'name': 'Prompt folder ${DateTime.now().millisecond}'},
      ) as Map;
      final id = '${folder['id']}';
      addTearDown(() => client.send('DELETE', '/api/v1/folders/$id'));
      await client.send(
        'POST',
        '/api/v1/folders/$id/update',
        body: {
          'data': {'system_prompt': 'Talk like a pirate'},
        },
      );
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(
            () => _Session(Session(serverUrl: url, token: client.token!)),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.future);
      await container.read(modelsProvider.future);
      final controller = container.read(chatControllerProvider.notifier);
      Future<String> ask({required bool temporary}) async {
        controller
          ..selectModel('fake')
          ..newChat(temporary: temporary, folderId: id);
        await controller.send('echo settings');
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (!container.read(chatControllerProvider).streaming) break;
        }
        final state = container.read(chatControllerProvider);
        expect(state.error, isNull);
        if (!temporary) await client.deleteChat(state.chat!.id);
        return state.messages.last.content;
      }

      expect(await ask(temporary: false), contains('Talk like a pirate'));
      expect(await ask(temporary: true), contains('Talk like a pirate'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
