// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/workspace/skill_files.dart';
import 'package:nexus_assistant/features/workspace/tools_skills.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('a skill\'s files: add, rename, delete, export and import', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    const id = 'nexus-files-skill';
    const copy = 'nexus-files-skill-copy';
    for (final s in [id, copy]) {
      try {
        await client.send('DELETE', '/api/v1/skills/id/$s/delete');
      } on ApiException {
        // Not there.
      }
    }
    addTearDown(() async {
      for (final s in [id, copy]) {
        try {
          await client.send('DELETE', '/api/v1/skills/id/$s/delete');
        } on ApiException {
          // Already gone.
        }
      }
    });
    await client.send(
      'POST',
      '/api/v1/skills/create',
      body: {
        'id': id,
        'name': 'Nexus files skill',
        'description': 'test',
        'content': '---\nname: nexus-files-skill\ndescription: test\n---\nHi',
      },
    );
    Future<Map> files() async =>
        await client.send('GET', '/api/v1/skills/id/$id/files') as Map;
    Future<void> apply(List<Map<String, dynamic>> ops) async => client.send(
      'POST',
      '/api/v1/skills/id/$id/update',
      body: {
        'id': id,
        'name': 'Nexus files skill',
        'operations': ops,
        'expected_version_id': (await files())['version_id'],
      },
    );
    await apply([
      putFile('notes/a.md', utf8.encode('alpha')),
      putFile('bin.dat', [0, 159, 146, 150]),
    ]);
    var listed = [for (final f in (await files())['files']) f['path']];
    expect(listed, containsAll(['SKILL.md', 'notes/a.md', 'bin.dat']));
    final now = await files();
    final text = await client.getBytes('/api/v1/skills/id/$id/files/content', {
      'path': 'notes/a.md',
      'version_id': '${now['version_id']}',
    });
    expect(utf8.decode(text), 'alpha');
    await apply([
      {'op': 'move', 'path': 'notes/a.md', 'destination': 'notes/b.md'},
      {'op': 'delete', 'path': 'bin.dat'},
    ]);
    listed = [for (final f in (await files())['files']) f['path']];
    expect(listed, unorderedEquals(['SKILL.md', 'notes/b.md']));

    // Export as .skill, then import it back as a copy.
    final package = await client.getBytes('/api/v1/skills/export', {
      'format': 'skill',
      'ids': id,
    });
    final preview =
        await client.sendFiles('/api/v1/skills/import/preview', [
              (package, '$id.skill'),
            ])
            as List;
    expect(preview.single['id_taken'], isTrue);
    final choice = ImportChoice((preview.single as Map).cast())
      ..action = 'copy';
    choice.id.text = copy;
    final done =
        await client.sendFiles(
              '/api/v1/skills/import',
              [(package, '$id.skill')],
              fields: {
                'decisions': jsonEncode([choice.decision()]),
              },
            )
            as List;
    expect(done.single['status'], 'saved', reason: '$done');
    final copied =
        await client.send('GET', '/api/v1/skills/id/$copy/files') as Map;
    expect([
      for (final f in copied['files']) f['path'],
    ], containsAll(['SKILL.md', 'notes/b.md']));
  }, skip: skip);

  test('a tool clone gets a valid id', () async {
    final id = cloneToolId('my-tool.v2', DateTime(2026, 1, 1, 0, 0, 12));
    expect(RegExp(r'^[a-z0-9_]+$').hasMatch(id), isTrue);
    expect(id, startsWith('my_tool_v2_copy_'));
  });
}
