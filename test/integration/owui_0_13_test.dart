// Runs against a real Open WebUI 0.13 server; see server_sync_test.dart.
// The features that release added: comment threads, the notification
// inbox, switching tools off, side chats, knowledge base file limits, and
// sub-agent models in the model editor. Comments need ENABLE_COMMENTS
// (tool/e2e/start_server.sh turns it on).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/chat_socket.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/comments/comments.dart';
import 'package:nexus_assistant/features/inbox/inbox.dart';
import 'package:nexus_assistant/features/workspace/knowledge_api.dart';
import 'package:uuid/uuid.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  var skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;
  var comments = false;
  late OpenWebUiClient client;

  setUpAll(() async {
    if (url == null) return;
    final c = OpenWebUiClient(baseUrl: url);
    final version =
        '${((await c.send('GET', '/api/version')) as Map)['version']}';
    final parts = version.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    if (parts.length < 3 || parts[0] == 0 && parts[1] < 13) {
      skip = 'Open WebUI $version is older than 0.13.0';
    }
    // Signed in: the full feature list.
    await c.signIn(email!, password!);
    comments =
        ((await c.config())['features'] as Map?)?['enable_comments'] == true;
  });

  setUp(() async {
    if (url == null) return;
    client = OpenWebUiClient(baseUrl: url);
    await client.signIn(email!, password!);
  });

  /// A second person, signed in.
  Future<OpenWebUiClient> friend() async {
    const mail = 'commenter@t.io', pass = 'Passw0rd!x';
    try {
      await client.send(
        'POST',
        '/api/v1/auths/add',
        body: {
          'name': 'Commenter',
          'email': mail,
          'password': pass,
          'role': 'user',
        },
      );
    } on ApiException {
      // Made by an earlier run.
    }
    final other = OpenWebUiClient(baseUrl: url!);
    await other.signIn(mail, pass);
    return other;
  }

  test('comments: write, reply, react, mention, edit, delete', () async {
    if (skip != null) return markTestSkipped(skip!);
    if (!comments) return markTestSkipped('Comments are off on this server');
    final api = CommentsApi(client);
    final chat = await client.createChat(
      Chat(
        id: '',
        title: 'comments test',
        messages: {
          'u1': ChatMessage(id: 'u1', role: 'user', content: 'what is 2+2'),
          'a1': ChatMessage(
            id: 'a1',
            role: 'assistant',
            content: 'It is four, as always.',
            parentId: 'u1',
          ),
        },
        currentId: 'a1',
      ),
    );
    final socket = ChatSocket(baseUrl: url!, token: client.token!);
    addTearDown(socket.dispose);
    await socket.ready(timeout: const Duration(seconds: 10));
    final changed = Completer<void>();
    final sub = socket.commentsChanged.listen((e) {
      if (e['resource_id'] == chat.id && !changed.isCompleted) {
        changed.complete();
      }
    });
    addTearDown(sub.cancel);
    socket.joinComments('test', 'chat', chat.id);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    try {
      expect(await api.count('chat', chat.id), 0);
      final first = await api.create('chat', chat.id, 'Nice chat');
      await changed.future.timeout(const Duration(seconds: 10));
      // On one reply, and on a passage of it.
      final onReply = await api.create(
        'chat',
        chat.id,
        'About this answer',
        targetType: 'chat_message',
        targetId: 'a1',
      );
      expect(onReply.targetId, 'a1');
      final anchor = CommentAnchor.find(
        quote: 'four',
        content: 'It is four, as always.',
      );
      expect(anchor, isNotNull);
      final onPassage = await api.create(
        'chat',
        chat.id,
        'Really?',
        targetType: 'chat_message',
        targetId: 'a1',
        anchor: anchor,
      );
      expect(onPassage.quote, 'four');

      // Replies, reactions, edits.
      final reply = await api.reply(first.id, 'Thanks');
      expect(reply.parentId, first.id);
      await api.react(first.id, '👍', on: true);
      var page = await api.list('chat', chat.id);
      expect(page.total, 4);
      final top = page.items.firstWhere((c) => c.id == first.id);
      expect(top.replyCount, 1);
      expect(top.reactions.single.name, '👍');
      expect(top.reactions.single.mine, isTrue);
      expect((await api.replies(first.id)).single.content, 'Thanks');
      await api.react(first.id, '👍', on: false);
      await api.edit(top, 'Nice chat, edited');
      page = await api.list('chat', chat.id);
      final edited = page.items.firstWhere((c) => c.id == first.id);
      expect(edited.content, 'Nice chat, edited');
      expect(edited.reactions, isEmpty);

      // Deleted comments keep their place, without their text.
      await api.delete(edited);
      page = await api.list('chat', chat.id);
      expect(page.items.firstWhere((c) => c.id == first.id).deleted, isTrue);
    } finally {
      socket.leaveComments('test');
      await client.deleteChat(chat.id);
    }
  });

  test('inbox: a mention arrives, live, with the count, and is read', () async {
    if (skip != null) return markTestSkipped(skip!);
    if (!comments) return markTestSkipped('Comments are off on this server');
    final other = await friend();
    final otherId = '${(await other.me())['id']}';
    final inbox = InboxApi(other);
    // Start from nothing new.
    await inbox.open();
    expect(await inbox.count(), 0);

    final socket = ChatSocket(baseUrl: url!, token: other.token!);
    addTearDown(socket.dispose);
    await socket.ready(timeout: const Duration(seconds: 10));
    final nudged = socket.inboxChanged.first.timeout(
      const Duration(seconds: 15),
    );

    // A note both can open, with a comment that mentions them.
    final note = (await client.send(
      'POST',
      '/api/v1/notes/create',
      body: {
        'title': 'inbox note',
        'data': {
          'content': {'md': 'hello'},
        },
        'access_grants': [
          {
            'principal_type': 'user',
            'principal_id': otherId,
            'permission': 'read',
          },
        ],
      },
    ) as Map).cast<String, dynamic>();
    final noteId = '${note['id']}';
    try {
      final mentions = await CommentsApi(client)
          .mentions('note', noteId, 'Comm');
      expect(mentions.map((m) => m.id), contains(otherId));
      await CommentsApi(client)
          .create('note', noteId, 'Have a look <@U:$otherId|Commenter>');
      await nudged;
      expect(await inbox.count(), 1);
      final page = await inbox.open();
      final item = page.items.first;
      expect(item.event, 'comment.mentioned');
      expect(item.resourceType, 'note');
      expect(item.resourceId, noteId);
      expect(item.title, 'inbox note');
      expect(
        item.label,
        'Unknown User mentioned you'.replaceAll('Unknown User', item.actor),
      );
      expect(item.fresh, isTrue);
      expect(item.read, isFalse);
      expect(await inbox.count(), 0, reason: 'opening the inbox sees it');
      await inbox.read(item.id);
      expect((await inbox.page(null)).items.first.read, isTrue);
    } finally {
      await client.send('DELETE', '/api/v1/notes/$noteId/delete');
    }
  });

  test('a tool switched off leaves chats but stays in the workspace', () async {
    if (skip != null) return markTestSkipped(skip!);
    final list = [
      for (final t in (await client.send('GET', '/api/v1/tools/list') as List))
        (t as Map).cast<String, dynamic>(),
    ];
    if (list.isEmpty) return markTestSkipped('No tool on this server');
    final tool = list.first;
    final id = '${tool['id']}';
    expect(tool['is_active'], isTrue);
    expect(tool['write_access'], isTrue);
    Future<Set<String>> usable() async => {
      for (final t in (await client.send('GET', '/api/v1/tools/') as List))
        '${(t as Map)['id']}',
    };
    expect(await usable(), contains(id));
    final off =
        (await client.send('POST', '/api/v1/tools/id/$id/toggle')) as Map;
    try {
      expect(off['is_active'], isFalse);
      expect(await usable(), isNot(contains(id)));
      final again = [
        for (final t
            in (await client.send('GET', '/api/v1/tools/list') as List))
          if ((t as Map)['id'] == id) t,
      ];
      expect(again.single['is_active'], isFalse);
    } finally {
      await client.send('POST', '/api/v1/tools/id/$id/toggle');
    }
    expect(await usable(), contains(id));
  });

  test('side chat: a temporary chat tied to this connection answers', () async {
    if (skip != null) return markTestSkipped(skip!);
    final socket = ChatSocket(baseUrl: url!, token: client.token!);
    addTearDown(socket.dispose);
    final sid = await socket.ready(timeout: const Duration(seconds: 10));
    expect(sid, isNotNull);
    final id = 'temporary:$sid:${const Uuid().v4()}';
    final user = ChatMessage(id: const Uuid().v4(), role: 'user', content: 'x');
    final replyId = const Uuid().v4();
    final done = Completer<String>();
    var text = '';
    final sub = socket.events
        .where((e) => e['chat_id'] == id && e['message_id'] == replyId)
        .listen((e) {
          final data = (e['data'] as Map?)?['data'];
          if ((e['data'] as Map?)?['type'] != 'chat:completion' ||
              data is! Map) {
            return;
          }
          final now = data['content'] is String
              ? data['content'] as String
              : ChatMessage.outputText(data['output']);
          if (now.isNotEmpty) text = now;
          if (data['done'] == true && !done.isCompleted) done.complete(text);
        });
    addTearDown(sub.cancel);
    await client.startTurn(
      model: 'fake',
      chatId: id,
      userMessage: ChatMessage(
        id: user.id,
        role: 'user',
        content: 'side question',
      ),
      replyId: replyId,
      sessionId: sid!,
      messages: [
        {'role': 'system', 'content': 'This is a separate side conversation.'},
        {'role': 'user', 'content': 'main chat so far'},
        {'role': 'user', 'content': 'side question'},
      ],
      options: const {'background_tasks': <String, Object>{}},
    );
    expect(
      await done.future.timeout(const Duration(seconds: 30)),
      contains('side question'),
    );
    // Someone else's connection can't take it over.
    await expectLater(
      client.startTurn(
        model: 'fake',
        chatId: 'temporary:not-my-socket:${const Uuid().v4()}',
        userMessage: user,
        replyId: const Uuid().v4(),
        sessionId: sid,
        messages: const [
          {'role': 'user', 'content': 'x'},
        ],
      ),
      throwsA(isA<ApiException>()),
    );
  });

  test(
    'knowledge base file limits: saved, and checked before upload',
    () async {
      if (skip != null) return markTestSkipped(skip!);
      final api = KnowledgeApi(client);
      final k = await api.create(
        'limits test',
        'two small files at most',
        limits: (count: 2, size: 1),
      );
      try {
        expect(k.maxFileCount, 2);
        expect(k.maxFileSize, 1);
        await api.checkUpload(k.id, 2, size: 1000);
        await expectLater(
          api.checkUpload(k.id, 3, size: 1000),
          throwsA(isA<ApiException>()),
        );
        await expectLater(
          api.checkUpload(k.id, 1, size: 5 * 1024 * 1024),
          throwsA(isA<ApiException>()),
        );
        await api.update(
          k.id,
          'limits test',
          'no limits now',
          limits: (count: null, size: null),
        );
        await api.checkUpload(k.id, 3, size: 5 * 1024 * 1024);
      } finally {
        await api.delete(k.id);
      }
    },
  );

  test(
    'a model keeps its sub-agent models and built-in tool switches',
    () async {
      if (skip != null) return markTestSkipped(skip!);
      const id = 'subagents-test';
      // Left by an earlier run that stopped half way.
      await client
          .send('POST', '/api/v1/models/model/delete', body: {'id': id})
          .catchError((_) => null);
      await client.send(
        'POST',
        '/api/v1/models/create',
        body: {
          'id': id,
          'name': 'Sub-agents test',
          'base_model_id': 'fake',
          'params': <String, Object>{},
          'meta': {
            'capabilities': {'builtin_tools': true},
            'builtinTools': {'tools': false},
            'subagents': {
              'model_ids': ['fake2'],
            },
          },
        },
      );
      try {
        final got = (await client.send(
          'GET',
          '/api/v1/models/model',
          query: {'id': id},
        ) as Map).cast<String, dynamic>();
        final meta = got['meta'] as Map;
        expect((meta['subagents'] as Map)['model_ids'], ['fake2']);
        expect((meta['builtinTools'] as Map)['tools'], isFalse);
      } finally {
        await client.send(
          'POST',
          '/api/v1/models/model/delete',
          body: {'id': id},
        );
      }
    },
  );
}
