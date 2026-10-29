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
    'messages queued during a reply go after it, together',
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
        ..selectModel(models.first.id);
      ChatState now() => container.read(chatControllerProvider);

      final first = controller.send('slow please');
      while (!now().streaming) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      controller
        ..queue('Queued one')
        ..queue('Queued two');
      expect(now().queued, ['Queued one', 'Queued two']);
      await first;
      for (var i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (now().messages.length == 4 && !now().streaming) break;
      }
      expect(now().error, isNull);
      expect(now().queued, isEmpty);
      expect(now().messages, hasLength(4));
      expect(now().messages[2].content, 'Queued one\n\nQueued two');
      expect(now().messages[3].content, contains('Queued two'));
      await client.deleteChat(now().chat!.id);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
