// Runs against a real Open WebUI 0.12.5 server; see server_sync_test.dart.
// The features that release added: note pages, files inside pages and live
// presence, the Sessions explorer, admins rotating a user's API key, and
// the chat's model saved as soon as it changes.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/chat_socket.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/admin/admin_api.dart';
import 'package:nexus_assistant/features/notes/notes_api.dart';
import 'package:nexus_assistant/features/studio/studio_api.dart';

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
    final parts = version.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    if (parts.length < 3 ||
        parts[0] == 0 && (parts[1] < 12 || parts[1] == 12 && parts[2] < 5)) {
      skip = 'Open WebUI $version is older than 0.12.5';
    }
  });

  setUp(() async {
    if (url == null) return;
    client = OpenWebUiClient(baseUrl: url);
    await client.signIn(email!, password!);
  });

  test('note pages: add, rename, nest, move, save each and delete', () async {
    if (skip != null) return markTestSkipped(skip!);
    final api = NotesApi(client);
    final note = await api.create('pages note', 'first page text');
    var got = await api.get(note.id);
    expect(got.paged, isTrue, reason: '0.12.5 lists a note\'s pages');
    expect(got.pages.single.id, 'main');

    got = await api.pages(
      note.id,
      'create',
      revision: got.pagesRevision,
      newId: '11111111-1111-4111-8111-111111111111',
      title: 'Day 1',
    );
    got = await api.pages(
      note.id,
      'create',
      revision: got.pagesRevision,
      newId: '22222222-2222-4222-8222-222222222222',
      parentId: '11111111-1111-4111-8111-111111111111',
      title: 'Morning',
    );
    expect(got.pages.map((p) => p.title), ['pages note', 'Day 1', 'Morning']);
    expect(pageDepth(got.pages, got.pages[2]), 1);

    // Each page saves its own text; the first keeps its own.
    await api.update(
      note.id,
      markdown: 'coffee',
      pageId: '22222222-2222-4222-8222-222222222222',
    );
    await api.update(note.id, markdown: 'plan', pageId: 'main');
    got = await api.get(note.id);
    expect(
      got.pages.firstWhere((p) => p.id.startsWith('2222')).markdown,
      'coffee',
    );
    expect(got.pages.first.markdown, 'plan');
    // Without a page, a note with several refuses the text (why the app
    // always says which page).
    await expectLater(
      api.update(note.id, markdown: 'lost'),
      throwsA(isA<ApiException>()),
    );

    got = await api.pages(
      note.id,
      'rename',
      revision: got.pagesRevision,
      pageId: '11111111-1111-4111-8111-111111111111',
      title: 'Monday',
    );
    expect(got.pages[1].title, 'Monday');
    // Move the subpage to the top level, then back up before Monday.
    got = await api.pages(
      note.id,
      'move',
      revision: got.pagesRevision,
      pageId: '22222222-2222-4222-8222-222222222222',
      toTop: true,
    );
    expect(got.pages.last.parentId, isNull);
    got = await api.pages(
      note.id,
      'move',
      revision: got.pagesRevision,
      pageId: '22222222-2222-4222-8222-222222222222',
      toTop: true,
      beforeId: '11111111-1111-4111-8111-111111111111',
    );
    expect(got.pages.map((p) => p.title), ['pages note', 'Morning', 'Monday']);

    // A stale revision is refused, so two editors can't clash.
    await expectLater(
      api.pages(note.id, 'rename', revision: 0, pageId: 'main', title: 'x'),
      throwsA(isA<ApiException>()),
    );

    got = await api.pages(
      note.id,
      'duplicate',
      revision: got.pagesRevision,
      pageId: '22222222-2222-4222-8222-222222222222',
      newId: '33333333-3333-4333-8333-333333333333',
    );
    expect(got.pages, hasLength(4));
    got = await api.pages(
      note.id,
      'delete',
      revision: got.pagesRevision,
      pageId: '33333333-3333-4333-8333-333333333333',
    );
    expect(got.pages, hasLength(3));

    // Lists show the page count.
    final listed = (await api.list()).firstWhere((n) => n.id == note.id);
    expect(listed.pageCount, 3);

    // The Studio reads and saves the first page only.
    final doc = await StudioApi(client).get(note.id);
    expect(doc.markdown, 'plan');
    await StudioApi(client)
        .save(note.id, title: 'pages note', markdown: 'plan 2');
    got = await api.get(note.id);
    expect(got.pages.first.markdown, 'plan 2');
    expect(got.pages, hasLength(3));
    await api.delete(note.id);
  });

  test('files sit inside the page they were added to', () async {
    if (skip != null) return markTestSkipped(skip!);
    final api = NotesApi(client);
    final note = await api.create('files in pages');
    final up = await client.uploadFile(
      'minutes from Tuesday'.codeUnits,
      'minutes.txt',
      contentType: 'text/plain',
    );
    final text = withFileLink('see the file', noteFileItem(up));
    await api.update(note.id, markdown: text, pageId: 'main');
    var got = await api.get(note.id);
    expect(pageFiles(got.pages.first.markdown).single['id'], up['id']);
    // The server reads the same file out of the page.
    final raw = await client.send('GET', '/api/v1/notes/${note.id}') as Map;
    expect(raw['data'].containsKey('files'), isFalse);
    await api.update(
      note.id,
      markdown: withoutFileLink(text, '${up['id']}'),
      pageId: 'main',
    );
    got = await api.get(note.id);
    expect(pageFiles(got.pages.first.markdown), isEmpty);
    expect(got.pages.first.markdown, 'see the file');
    await api.delete(note.id);
  });

  test('live presence: who has a note open', () async {
    if (skip != null) return markTestSkipped(skip!);
    final note = await NotesApi(client).create('presence note');
    final socket = ChatSocket(baseUrl: url!, token: client.token!);
    try {
      final seen = socket.notePresence
          .where((e) => e['note_id'] == note.id)
          .first
          .timeout(const Duration(seconds: 15));
      socket.joinNote(note.id);
      final e = await seen;
      final me = (await client.send('GET', '/api/v1/auths/') as Map)['id'];
      expect((e['users'] as List).map((u) => u['id']), contains(me));

      // A page change made elsewhere arrives as events:note.
      final changed = socket.noteEvents
          .where((e) => e['id'] == note.id)
          .first
          .timeout(const Duration(seconds: 15));
      final n = await NotesApi(client).get(note.id);
      await NotesApi(client).pages(
        note.id,
        'create',
        revision: n.pagesRevision,
        newId: '44444444-4444-4444-8444-444444444444',
        title: 'Elsewhere',
      );
      final ev = await changed;
      expect((ev['data'] as Map)['pages'], hasLength(2));
      socket.leaveNote(note.id);
    } finally {
      socket.dispose();
      await NotesApi(client).delete(note.id);
    }
  });

  test('Sessions explorer lists chats and opens one', () async {
    if (skip != null) return markTestSkipped(skip!);
    final models =
        ((await client.send('GET', '/api/models')) as Map)['data'] as List;
    final model = '${models.first['id']}';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final chat = await client.send(
      'POST',
      '/api/v1/chats/new',
      body: {
        'chat': {
          'title': 'sessions e2e chat',
          'models': [model],
          'history': {
            'currentId': 'a1',
            'messages': {
              'u1': {
                'id': 'u1',
                'role': 'user',
                'content': 'hello',
                'childrenIds': ['a1'],
                'timestamp': now,
              },
              'a1': {
                'id': 'a1',
                'parentId': 'u1',
                'role': 'assistant',
                'content': 'hi there',
                'model': model,
                'done': true,
                'childrenIds': [],
                'timestamp': now,
                'usage': {'input_tokens': 5, 'output_tokens': 7},
              },
            },
          },
        },
      },
    ) as Map;
    try {
      final list = await client.send(
        'GET',
        '/api/v1/analytics/sessions',
        query: {'query': 'sessions e2e', 'include_summary': 'true'},
      ) as Map;
      expect(list['items'], isA<List>());
      expect(list['overview'], isA<Map>());
      expect(list['overview']['token_distribution'], hasLength(6));
      final item = (list['items'] as List).cast<Map>().firstWhere(
        (i) => i['id'] == chat['id'],
      );
      expect(item['responses'], 1);
      final detail = await client.send(
        'GET',
        '/api/v1/analytics/sessions/${chat['id']}',
      ) as Map;
      final reply = (detail['items'] as List).cast<Map>().firstWhere(
        (m) => m['role'] == 'assistant',
      );
      // The server names each message chat id + "-" + message id; the app
      // opens a reply's tool calls by the id the detail gave it.
      expect(reply['id'], '${chat['id']}-a1');
      final events = await client.send(
        'GET',
        '/api/v1/analytics/sessions/${chat['id']}/messages/'
            '${Uri.encodeComponent('${reply['id']}')}/events',
      ) as Map;
      expect(events['items'], isA<List>());
    } finally {
      await client.send('DELETE', '/api/v1/chats/${chat['id']}');
    }
  });

  test('admins rotate and delete a user\'s API key', () async {
    if (skip != null) return markTestSkipped(skip!);
    final admin = AdminApi(client);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await admin.addUser(
      name: 'Key Person',
      email: 'key$stamp@example.com',
      password: 'Secret-pass-1',
      role: 'admin',
    );
    final users = await admin.users(query: 'key$stamp');
    final u = users.firstWhere((u) => u.email == 'key$stamp@example.com');
    try {
      final key = await admin.rotateUserApiKey(u.id);
      expect(key, startsWith('sk-'));
      // The key works as that person (the account page itself wants a
      // signed-in session, so check what the key creates).
      final asThem = OpenWebUiClient(baseUrl: url!)..token = key;
      final note = await asThem.send(
        'POST',
        '/api/v1/notes/create',
        body: {'title': 'made with a key'},
      ) as Map;
      expect(note['user_id'], u.id);
      final again = await admin.rotateUserApiKey(u.id);
      expect(again, isNot(key));
      await admin.deleteUserApiKey(u.id);
      final gone = OpenWebUiClient(baseUrl: url)..token = again;
      await expectLater(
        gone.send('GET', '/api/models'),
        throwsA(isA<ApiException>()),
      );
    } finally {
      await admin.deleteUser(u.id);
    }
  });

  test('the chat keeps the model picked, even with no message after', () async {
    if (skip != null) return markTestSkipped(skip!);
    final models =
        ((await client.send('GET', '/api/models')) as Map)['data'] as List;
    if (models.length < 2) return markTestSkipped('Needs two models');
    final chat = await client.send(
      'POST',
      '/api/v1/chats/new',
      body: {
        'chat': {
          'title': 'model pick e2e',
          'models': [models.first['id']],
        },
      },
    ) as Map;
    try {
      await client.patchChat('${chat['id']}', {
        'models': [models[1]['id']],
      });
      final saved = await client.chat('${chat['id']}');
      expect(saved.models, [models[1]['id']]);
    } finally {
      await client.send('DELETE', '/api/v1/chats/${chat['id']}');
    }
  });
}
