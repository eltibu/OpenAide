// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/chat/search_everywhere.dart';
import 'package:nexus_assistant/features/notes/notes_screen.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('results open where the web would', () {
    expect(searchTarget('/c/abc'), ('chat', 'abc'));
    expect(searchTarget('/channels/ch1?thread=m1&message=m2'), (
      'channel',
      'ch1',
    ));
    expect(searchTarget('/notes/n1'), ('note', 'n1'));
    expect(searchTarget('/s/snap'), isNull);
    expect(noteTitlePrompt('Groceries: milk'), contains('Groceries: milk'));
  });

  test('a chat is found by its title', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final word = 'zebra${DateTime.now().millisecondsSinceEpoch % 100000}';
    final made = await client.send(
      'POST',
      '/api/v1/chats/new',
      body: {
        'chat': {'title': 'Find the $word', 'messages': []},
      },
    ) as Map;
    try {
      final res = await client.send(
        'GET',
        '/api/v1/search',
        query: {
          'q': word,
          'kind': 'chat',
          'sharing': 'all',
          'scope': '',
          'page': '1',
        },
      ) as Map;
      final items = res['items'] as List;
      expect(items.any((i) => i['url'] == '/c/${made['id']}'), isTrue);
      expect(res['kinds'], contains('chat'));
      expect(res, contains('scopes'));
    } finally {
      await client.send('DELETE', '/api/v1/chats/${made['id']}');
    }
  }, skip: skip);
}
