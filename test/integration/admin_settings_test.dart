// Runs against a real Open WebUI server as an admin; see
// server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/admin/config_editor.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('every settings page reads and saves its settings', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    for (final s in adminConfigSections) {
      final all = (await client.send('GET', s.read) as Map)
          .cast<String, dynamic>();
      var part = all;
      for (final k in s.path) {
        part = (part[k] as Map).cast<String, dynamic>();
      }
      expect(part, isNotEmpty, reason: s.title);
      for (final k in s.engines.keys) {
        if (s.path.isEmpty || part.containsKey(k)) {
          expect(part.containsKey(k), isTrue, reason: '${s.title} $k');
        }
      }
      await client.send('POST', s.save, body: {...all}..remove('status'));
    }

    // A change is kept.
    final tasks = adminConfigSections.firstWhere(
      (s) => s.title == 'Interface and tasks',
    );
    final before = (await client.send('GET', tasks.read) as Map)
        .cast<String, dynamic>();
    final was = before['ENABLE_TAGS_GENERATION'] as bool;
    await client.send(
      'POST',
      tasks.save,
      body: {...before, 'ENABLE_TAGS_GENERATION': !was},
    );
    expect(
      (await client.send('GET', tasks.read) as Map)['ENABLE_TAGS_GENERATION'],
      !was,
    );
    await client.send('POST', tasks.save, body: before);
  }, skip: skip);
}
