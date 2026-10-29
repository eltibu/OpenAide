// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/chat/shared_folders.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('shares a folder read only, with replies allowed', () async {
    final me = OpenWebUiClient(baseUrl: url!);
    await me.signIn(email!, password!);
    final friend = OpenWebUiClient(baseUrl: url);
    try {
      await friend.signIn('friend@t.io', 'Passw0rd!x');
    } catch (_) {
      await me.send(
        'POST',
        '/api/v1/auths/add',
        body: {
          'name': 'Friend',
          'email': 'friend@t.io',
          'password': 'Passw0rd!x',
          'role': 'user',
        },
      );
      await friend.signIn('friend@t.io', 'Passw0rd!x');
    }
    final friendId = '${(await friend.me())['id']}';
    final folder = await me.send(
      'POST',
      '/api/v1/folders/',
      body: {'name': 'nexus shared'},
    ) as Map;
    final id = '${folder['id']}';
    try {
      final chat = await me.send(
        'POST',
        '/api/v1/chats/new',
        body: {
          'chat': {'title': 'Trip plan', 'messages': <Object>[]},
          'folder_id': id,
        },
      ) as Map;
      await me.send(
        'POST',
        '/api/v1/folders/$id/access/update',
        body: {
          'access_grants': [
            {
              'principal_type': 'user',
              'principal_id': friendId,
              'permission': 'read',
            },
          ],
          'share_mode': 'continue',
        },
      );
      final got = await me.send('GET', '/api/v1/folders/$id') as Map;
      expect((got['data'] as Map?)?['share_mode'], 'continue');

      final shared = [
        for (final f in (await friend.send(
          'GET',
          '/api/v1/folders/shared',
        ) as List).whereType<Map>())
          SharedFolder.fromJson(f),
      ];
      final mine = shared.firstWhere((f) => f.id == id);
      expect(mine.writable, isFalse);
      expect(mine.name, 'nexus shared');
      final res = await friend.send(
        'GET',
        '/api/v1/folders/$id/shared/chats',
        query: {'page': '1'},
      ) as Map;
      final chats = [
        for (final c in (res['chats'] as List).whereType<Map>())
          SharedChat.fromJson(c),
      ];
      expect(chats.single.id, chat['id']);
      expect(chats.single.title, 'Trip plan');
      expect(chats.single.readOnly, isTrue);
    } finally {
      await me.send('DELETE', '/api/v1/folders/$id');
    }
  }, skip: skip);
}
