// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/models/chat.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('rename, pin, folders, search, archive and delete', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);

    final chat = await client.createChat(
      Chat(
        id: '',
        title: 'Nexus manage test',
        messages: {
          'u1': ChatMessage(id: 'u1', role: 'user', content: 'zebra crossing'),
        },
        currentId: 'u1',
      ),
    );
    String? folderId;
    Future<Set<String>> ids(Future<List<ChatSummary>> list) async => {
      for (final c in await list) c.id,
    };
    try {
      await client.renameChat(chat.id, 'Renamed by Nexus');
      final renamed = await client.chat(chat.id);
      expect(renamed.title, 'Renamed by Nexus');
      expect(renamed.messages['u1']?.content, 'zebra crossing');

      await client.togglePin(chat.id);
      expect(await ids(client.pinnedChats()), contains(chat.id));
      expect(await ids(client.chats()), isNot(contains(chat.id)));
      await client.togglePin(chat.id);
      expect(await ids(client.pinnedChats()), isNot(contains(chat.id)));

      await client.createFolder('Nexus test folder');
      folderId = (await client.folders())
          .firstWhere((f) => f.name == 'Nexus test folder')
          .id;
      await client.renameFolder(folderId, 'Nexus folder 2');
      expect(
        (await client.folders()).map((f) => f.name),
        contains('Nexus folder 2'),
      );
      await client.moveChat(chat.id, folderId);
      expect(await ids(client.folderChats(folderId)), contains(chat.id));
      expect(await ids(client.chats()), isNot(contains(chat.id)));

      expect(await ids(client.searchChats('zebra')), contains(chat.id));

      // Deleting the folder keeps its chats.
      await client.deleteFolder(folderId);
      folderId = null;
      expect(await ids(client.chats()), contains(chat.id));

      await client.toggleArchive(chat.id);
      expect(await ids(client.chats()), isNot(contains(chat.id)));
    } finally {
      if (folderId != null) await client.deleteFolder(folderId);
      await client.deleteChat(chat.id);
    }
  }, skip: skip);
}
