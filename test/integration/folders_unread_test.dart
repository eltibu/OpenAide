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

  test('a new chat in a folder, unread marks and folder export', () async {
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
    await client.createFolder('Unread test');
    final folder = (await client.folders()).firstWhere(
      (f) => f.name == 'Unread test',
    );
    addTearDown(() => client.deleteFolder(folder.id));

    final controller = container.read(chatControllerProvider.notifier)
      ..selectModel('fake')
      ..newChat(temporary: false, folderId: folder.id);
    await controller.send('in the folder');
    final id = container.read(chatControllerProvider).chat!.id;
    final inFolder = await client.folderChats(folder.id);
    expect(inFolder.map((c) => c.id), contains(id));

    // Marked unread: shown on the chat and counted on its folder.
    await client.send('POST', '/api/v1/chats/$id/unread');
    expect(
      (await client.folderChats(folder.id))
          .firstWhere((c) => c.id == id)
          .unread,
      isTrue,
    );
    expect(
      (await client.folders()).firstWhere((f) => f.id == folder.id).unread,
      greaterThan(0),
    );
    await client.send('POST', '/api/v1/folders/${folder.id}/read');
    expect(
      (await client.folderChats(folder.id))
          .firstWhere((c) => c.id == id)
          .unread,
      isFalse,
    );

    // Export: the folder's chats in full.
    final exported = await client.send(
      'GET',
      '/api/v1/chats/folder/${folder.id}',
    );
    expect((exported as List).map((c) => (c as Map)['id']), contains(id));
  }, skip: skip);
}
