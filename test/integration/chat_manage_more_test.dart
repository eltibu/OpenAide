// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/chat/chat_drawer.dart';

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
    'folder settings, many chats at once, tags and clone',
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

      // A folder's system prompt, saved the way the settings sheet saves it,
      // is used for chats in the folder.
      await client.createFolder('Pirates');
      final folder = (await client.folders()).firstWhere(
        (f) => f.name == 'Pirates',
      );
      await client.send(
        'POST',
        '/api/v1/folders/${folder.id}/update',
        body: {
          'name': 'Pirate talk',
          'data': {'system_prompt': 'Talk like a pirate.', 'files': []},
        },
      );
      await controller.send('first');
      final a = now().chat!.id;
      await controller.moveChat(a, folder.id);
      await controller.open(a);
      await controller.send('echo settings');
      expect(now().messages.last.content, contains('Talk like a pirate.'));
      final saved =
          (await client.send('GET', '/api/v1/folders/${folder.id}') as Map);
      expect(saved['name'], 'Pirate talk');

      // Clone, then archive both together, as the selection bar does.
      final res = await client.send(
        'POST',
        '/api/v1/chats/$a/clone',
        body: {'title': 'Clone of x'},
      );
      final b = (res as Map)['id'] as String;
      final selection = container.read(chatSelectionProvider.notifier)
        ..start(a)
        ..toggle(b);
      expect(container.read(chatSelectionProvider), {a, b});
      for (final id in container.read(chatSelectionProvider)!) {
        await controller.archiveChat(id);
      }
      selection.clear();
      final listed = (await client.chats()).map((c) => c.id);
      expect(listed, isNot(contains(a)));
      expect(listed, isNot(contains(b)));

      await client.deleteChat(a);
      await client.deleteChat(b);
      await client.deleteFolder(folder.id);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
