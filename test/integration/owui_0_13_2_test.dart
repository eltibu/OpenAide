// Runs against a real Open WebUI 0.13.1 or newer; see server_sync_test.dart.
// What OpenAide does with 0.13.1/0.13.2: side chats saved as chats, the
// channel message search, a folder's default terminal and working folder,
// the new chat settings (tool call labels, Auto tool permissions, tool
// search engines), default tools for models, and asking for a terminal's
// coding agents.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/chat/side_chat.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  var skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;
  late OpenWebUiClient client;

  setUpAll(() async {
    if (url == null) return;
    final c = OpenWebUiClient(baseUrl: url);
    final version =
        '${((await c.send('GET', '/api/version')) as Map)['version']}';
    if (!serverSavesSideChats(version)) {
      skip = 'Open WebUI $version is older than 0.13.1';
    }
  });

  setUp(() async {
    if (url == null) return;
    client = OpenWebUiClient(baseUrl: url);
    await client.signIn(email!, password!);
  });

  test('a side chat is saved as its own chat, linked to its parent', () async {
    if (skip != null) return markTestSkipped(skip!);
    final branch = [
      {'id': 'u1', 'role': 'user', 'content': 'what is 2+2', 'timestamp': 1},
      {
        'id': 'a1',
        'role': 'assistant',
        'content': '4',
        'model': 'fake',
        'timestamp': 2,
      },
    ];
    final id = await client.createSideChat(
      title: 'side question',
      model: 'fake',
      system: 'side',
      history: sideChatHistory(branch),
      messages: branch,
      originalChatId: 'parent-chat',
      branchPointMessageId: 'a1',
    );
    final saved = (await client.send('GET', '/api/v1/chats/$id') as Map);
    expect(saved['title'], 'side question');
    final body = saved['chat'] as Map;
    expect(body['originalChatId'], 'parent-chat');
    expect(body['branchPointMessageId'], 'a1');
    expect((body['params'] as Map)['system'], 'side');
    final chat = await client.chat(id);
    expect(chat.messages.keys, containsAll(['u1', 'a1']));
    expect(chat.currentId, 'a1');
    // It shows in the chat list, as on the web.
    final list = await client.chats();
    expect(list.any((c) => c.id == id), isTrue);
    await client.deleteChat(id);
  });

  test('a channel search looks in that channel only', () async {
    if (skip != null) return markTestSkipped(skip!);
    final channels = await client.send('GET', '/api/v1/channels/') as List;
    if (channels.isEmpty) return markTestSkipped('No channel on the server');
    final cid = '${(channels.first as Map)['id']}';
    final word = 'zebra${DateTime.now().millisecondsSinceEpoch}';
    await client.send(
      'POST',
      '/api/v1/channels/$cid/messages/post',
      body: {'content': 'a $word in the channel'},
    );
    final res =
        await client.send(
              'GET',
              '/api/v1/search',
              query: {
                'q': word,
                'kind': 'message',
                'sharing': 'all',
                'scope': 'channel:$cid',
                'page': '1',
              },
            )
            as Map;
    final items = (res['items'] as List).whereType<Map>().toList();
    expect(items, isNotEmpty);
    final elsewhere =
        await client.send(
              'GET',
              '/api/v1/search',
              query: {
                'q': word,
                'kind': 'message',
                'sharing': 'all',
                'scope': 'channel:not-a-channel',
                'page': '1',
              },
            )
            as Map;
    expect(elsewhere['items'] as List, isEmpty);
  });

  test('a folder keeps its default terminal and working folder', () async {
    if (skip != null) return markTestSkipped(skip!);
    final folder =
        await client.send(
              'POST',
              '/api/v1/folders/',
              body: {'name': 'Terminal folder ${DateTime.now().millisecond}'},
            )
            as Map;
    final id = folder['id'];
    await client.send(
      'POST',
      '/api/v1/folders/$id/update',
      body: {
        'data': {'terminal_id': 'local', 'working_directory': '/tmp/project'},
      },
    );
    final back = await client.send('GET', '/api/v1/folders/$id') as Map;
    expect((back['data'] as Map)['terminal_id'], 'local');
    expect((back['data'] as Map)['working_directory'], '/tmp/project');
    await client.send('DELETE', '/api/v1/folders/$id');
  });

  test('chat settings have labels, Auto permissions and search engines', () async {
    if (skip != null) return markTestSkipped(skip!);
    final config = await client.send('GET', '/api/v1/chats/config') as Map;
    for (final key in [
      'ENABLE_TOOL_CALL_LABELS',
      'ENABLE_TOOL_PERMISSIONS_AUTO',
      'TOOL_PERMISSIONS_AUTO_ENGINE',
      'TOOL_SEARCH_ENGINE',
    ]) {
      expect(config.containsKey(key), isTrue, reason: key);
    }
    // Saving it back as read (with the read-only defaults in it) works, as
    // the admin page does.
    final saved =
        await client.send(
              'POST',
              '/api/v1/chats/config',
              body: {...config, 'ENABLE_TOOL_CALL_LABELS': true},
            )
            as Map;
    expect(saved['ENABLE_TOOL_CALL_LABELS'], isTrue);
    await client.send(
      'POST',
      '/api/v1/chats/config',
      body: {...config, 'ENABLE_TOOL_CALL_LABELS': false},
    );
  });

  test('default tools reach models without their own', () async {
    if (skip != null) return markTestSkipped(skip!);
    final tools = await client.send('GET', '/api/v1/tools/') as List;
    if (tools.isEmpty) return markTestSkipped('No tool on the server');
    final tool = '${(tools.first as Map)['id']}';
    final before =
        await client.send('GET', '/api/v1/configs/models') as Map;
    final meta = {...?(before['DEFAULT_MODEL_METADATA'] as Map?)};
    try {
      await client.send(
        'POST',
        '/api/v1/configs/models',
        body: {
          ...before,
          'DEFAULT_MODEL_METADATA': {
            ...meta,
            'toolIds': [tool],
          },
        },
      );
      final models = await client.models();
      final fake = models.firstWhere((m) => m.id == 'fake');
      expect(fake.toolIds, contains(tool));
    } finally {
      await client.send('POST', '/api/v1/configs/models', body: before);
    }
  });

  test('asking for a terminal\'s coding agents keeps the model list', () async {
    if (skip != null) return markTestSkipped(skip!);
    final plain = await client.models();
    final withTerminal = await client.models(terminalId: 'local');
    // The test terminal offers no agents; the list is the same and never
    // fails.
    expect(
      withTerminal.where((m) => !m.isAgent).map((m) => m.id).toSet(),
      plain.map((m) => m.id).toSet(),
    );
  });
}
