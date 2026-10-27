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
    'a chat\'s own system prompt and settings are used and saved',
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
      await container.read(modelsProvider.future);
      final controller = container.read(chatControllerProvider.notifier)
        ..selectModel('fake');
      ChatState now() => container.read(chatControllerProvider);

      // Set before the first message: used, then saved with the new chat.
      await controller.setParam('system', 'You are a pirate.');
      await controller.setParam('temperature', 0.3);
      await controller.send('echo settings please');
      expect(now().error, isNull);
      expect(
        now().messages.last.content,
        contains('System was: You are a pirate.'),
      );
      expect(now().messages.last.content, contains('temperature=0.3'));
      final id = now().chat!.id;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      var saved = await client.chat(id);
      expect(saved.extra['params'], {
        'system': 'You are a pirate.',
        'temperature': 0.3,
      });

      // Changed later: saved right away, and the default comes back.
      await controller.setParam('temperature', null);
      saved = await client.chat(id);
      expect(saved.extra['params'], {
        'system': 'You are a pirate.',
        'temperature': null,
      });
      await controller.send('echo settings again');
      expect(now().messages.last.content, contains('temperature=None'));

      // Opening the chat brings its controls back; a new chat starts clean.
      controller.newChat();
      expect(now().params, isEmpty);
      await controller.open(id);
      expect(now().params, {'system': 'You are a pirate.'});
      await client.deleteChat(id);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
