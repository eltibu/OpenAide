// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/workspace/code_editor.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('ids are Python names', () {
    expect(codeIdFrom('My Weather Tool!'), 'my_weather_tool');
    expect(codeIdFrom('  2 step  '), '_2_step');
    expect(codeIdFrom('a--b'), 'a_b');
  });

  test('the starters are accepted, then edited and removed', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
    for (final (kind, base, code) in [
      ('tool', '/api/v1/tools', toolStarter),
      ('function', '/api/v1/functions', functionStarter),
    ]) {
      final id = codeIdFrom('nexus test $kind $stamp');
      await client.send(
        'POST',
        '$base/create',
        body: {
          'id': id,
          'name': 'Nexus test $kind',
          'content': code,
          'meta': {'description': 'first'},
        },
      );
      await client.send(
        'POST',
        '$base/id/$id/update',
        body: {
          'id': id,
          'name': 'Nexus test $kind',
          'content': '$code\n# edited\n',
          'meta': {'description': 'second'},
        },
      );
      final saved = await client.send('GET', '$base/id/$id') as Map;
      expect('${saved['content']}', contains('# edited'));
      expect((saved['meta'] as Map)['description'], 'second');
      await client.send('DELETE', '$base/id/$id/delete');
    }
  }, skip: skip);
}
