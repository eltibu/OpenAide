// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/admin/events_screen.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('event filters and audiences', () {
    const events = ['user.created', 'user.deleted', 'chat.created'];
    expect(validEventPattern('*', events), isTrue);
    expect(validEventPattern('user.created', events), isTrue);
    expect(validEventPattern('user.*', events), isTrue);
    expect(validEventPattern('nope.*', events), isFalse);
    expect(validEventPattern('user', events), isFalse);
    expect(addEventFilter(['*'], 'user.*'), ['user.*']);
    expect(addEventFilter(['user.*'], 'user.*'), ['user.*']);
    expect(addEventFilter(['user.*'], '*'), ['*']);
    expect(webhookAudience(null), 'All users and system events');
    expect(webhookAudience([]), 'System events only');
    expect(
      webhookAudience([
        {'type': 'user', 'id': 'a'},
        {'type': 'group', 'id': 'b'},
        {'type': 'group', 'id': 'c'},
      ]),
      '1 user, 2 groups',
    );
  });

  test('a webhook is added, changed and removed', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final made = await client.send(
      'POST',
      '/api/events/webhooks',
      body: {
        'name': 'Nexus test hook',
        'url': 'https://93.184.216.34/nexus-hook',
        'enabled': true,
        'events': ['user.*'],
        'targets': <Map>[],
      },
    ) as Map;
    final id = made['id'];
    addTearDown(() async {
      try {
        await client.send('DELETE', '/api/events/webhooks/$id');
      } on ApiException {
        // Already gone.
      }
    });
    await client.send(
      'PUT',
      '/api/events/webhooks/$id',
      body: {'enabled': false},
    );
    final list = await client.send('GET', '/api/events/webhooks') as List;
    final hook = list.firstWhere((h) => h['id'] == id) as Map;
    expect(hook['enabled'], isFalse);
    expect(hook['events'], ['user.*']);
    expect(hook['targets'], isEmpty);
    await client.send('DELETE', '/api/events/webhooks/$id');
    final after = await client.send('GET', '/api/events/webhooks') as List;
    expect(after.any((h) => h['id'] == id), isFalse);
  }, skip: skip);
}
