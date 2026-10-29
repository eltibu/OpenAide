// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/workspace/version_history.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('a prompt\'s older version goes back into use', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final made = await client.send(
      'POST',
      '/api/v1/prompts/create',
      body: {
        'command': 'nexushist',
        'name': 'Nexus history',
        'content': 'first',
      },
    );
    final id = '${made['id']}';
    addTearDown(() => client.send('DELETE', '/api/v1/prompts/id/$id/delete'));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await client.send(
      'POST',
      '/api/v1/prompts/id/$id/update',
      body: {
        'command': 'nexushist',
        'name': 'Nexus history',
        'content': 'second',
      },
    );
    final paths = HistoryPaths('prompt', id);
    final (listPath, listQuery) = paths.list(1);
    final versions =
        await client.send('GET', listPath, query: listQuery) as List;
    expect(versions.length, greaterThanOrEqualTo(2));
    // Newest first.
    final oldest = versions.last as Map;
    final (entryPath, entryQuery) = paths.entry('${oldest['id']}');
    final entry = await client.send('GET', entryPath, query: entryQuery);
    expect(snapshotText(entry['snapshot'] as Map), 'first');
    expect(
      (await client.send('GET', paths.current))['version_id'],
      (versions.first as Map)['id'],
    );
    final (prodPath, prodQuery) = paths.production();
    await client.send(
      'POST',
      prodPath,
      query: prodQuery,
      body: {'version_id': oldest['id']},
    );
    final now = await client.send('GET', paths.current);
    expect(now['content'], 'first');
  }, skip: skip);
}
