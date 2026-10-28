// Runs against a real Open WebUI server as an admin; see
// server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('ratings show in feedback, the leaderboard and analytics', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    const base = '/api/v1/evaluations';
    final made = await client.send(
      'POST',
      '$base/feedback',
      body: {
        'type': 'rating',
        'data': {
          'rating': -1,
          'model_id': 'fake',
          'sibling_model_ids': ['fake2'],
          'reason': 'Not helpful',
          'comment': 'test',
        },
        'meta': {
          'arena': true,
          'tags': ['testing'],
        },
      },
    ) as Map;
    // Earlier runs leave feedback behind, so look through the pages.
    Map? item;
    for (var page = 1; item == null && page <= 50; page++) {
      final list = await client.send(
        'GET',
        '$base/feedbacks/list',
        query: {'page': '$page', 'model_id': 'fake'},
      ) as Map;
      final items = list['items'] as List;
      if (items.isEmpty) break;
      item = items.firstWhere(
        (f) => f['id'] == made['id'],
        orElse: () => null,
      ) as Map?;
    }
    item!;
    expect((item['data'] as Map)['reason'], 'Not helpful');
    expect((item['user'] as Map)['name'], isNotEmpty);
    expect(
      await client.send('GET', '$base/feedbacks/models'),
      contains('fake'),
    );
    final board = await client.send('GET', '$base/leaderboard') as Map;
    expect([
      for (final e in board['entries'] as List) e['model_id'],
    ], contains('fake2'));
    expect(await client.send('GET', '$base/feedbacks/all/export'), isNotEmpty);
    await client.send('DELETE', '$base/feedback/${made['id']}');

    for (final p in ['summary', 'models', 'users', 'daily', 'tokens']) {
      expect(await client.send('GET', '/api/v1/analytics/$p'), isA<Map>());
    }
  }, skip: skip);
}
