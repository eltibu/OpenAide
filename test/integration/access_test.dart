// Runs against a real Open WebUI server as an admin; see
// server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/notes/notes_api.dart';
import 'package:nexus_assistant/features/workspace/access_editor.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('access grants save for notes and prompts', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final note = await NotesApi(client).create('Access test');
    final group = await client.send(
      'POST',
      '/api/v1/groups/create',
      body: {'name': 'Access test group', 'description': ''},
    ) as Map;
    try {
      final grants = <Grant>[
        (type: 'user', id: '*', permission: 'read'),
        (type: 'group', id: '${group['id']}', permission: 'read'),
        (type: 'group', id: '${group['id']}', permission: 'write'),
      ];
      await client.send(
        'POST',
        accessPath('note', note.id),
        body: {'access_grants': writeGrants(grants)},
      );
      final back = readGrants(
        (await client.send('GET', itemPath('note', note.id))
            as Map)['access_grants'],
      );
      expect(back.toSet(), grants.toSet());

      await client.send(
        'POST',
        '/api/v1/prompts/create',
        body: {'command': 'access-test', 'name': 'Access test', 'content': 'x'},
      );
      final prompts = await client.send('GET', '/api/v1/prompts/') as List;
      final p = prompts.firstWhere((p) => p['command'] == 'access-test') as Map;
      final id = '${p['id'] ?? p['command']}';
      await client.send(
        'POST',
        accessPath('prompt', id),
        body: {'access_grants': writeGrants(grants.take(1).toList())},
      );
      expect(
        readGrants(
          (await client.send('GET', itemPath('prompt', id))
              as Map)['access_grants'],
        ),
        [(type: 'user', id: '*', permission: 'read')],
      );
      await client.send('DELETE', '/api/v1/prompts/id/$id/delete');
    } finally {
      await client.send('DELETE', '/api/v1/notes/${note.id}/delete');
      await client.send('DELETE', '/api/v1/groups/id/${group['id']}/delete');
    }
  }, skip: skip);
}
