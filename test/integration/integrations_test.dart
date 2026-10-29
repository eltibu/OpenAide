// Runs against a real Open WebUI server as an admin; see
// server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/admin/integrations_screen.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('tool and terminal servers save as the web saves them', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    for (final k in [toolServerKind, terminalServerKind]) {
      final before = (await client.send('GET', k.path) as Map)[k.key];
      final c = k.blank()..['url'] = 'http://127.0.0.1:9';
      if (k == toolServerKind) {
        (c['info'] as Map)['name'] = 'Test tools';
      } else {
        c['name'] = 'Test terminal';
        c['id'] = 'test-terminal';
      }
      setPublicConnection(c, false);
      await client.send(
        'POST',
        k.path,
        body: {
          k.key: [c],
        },
      );
      final saved =
          ((await client.send('GET', k.path) as Map)[k.key] as List).single
              as Map<String, dynamic>;
      expect(k.label(saved), startsWith('Test'));
      expect(k.enabled(saved), isTrue);
      expect(isPublicConnection(saved), isFalse);
      setPublicConnection(saved, true);
      k.setEnabled(saved, false);
      await client.send(
        'POST',
        k.path,
        body: {
          k.key: [saved],
        },
      );
      final again =
          ((await client.send('GET', k.path) as Map)[k.key] as List).single
              as Map<String, dynamic>;
      expect(isPublicConnection(again), isTrue);
      expect(k.enabled(again), isFalse);
      await client.send('POST', k.path, body: {k.key: before ?? []});
    }
  }, skip: skip);
}
