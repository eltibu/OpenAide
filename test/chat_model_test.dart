import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/sse.dart';
import 'package:nexus_assistant/core/models/chat.dart';

void main() {
  group('Chat', () {
    final serverJson = {
      'id': 'c1',
      'title': 'Trip ideas',
      'chat': {
        'title': 'Trip ideas',
        'models': ['llama3'],
        'params': {'temperature': 0.2},
        'history': {
          'currentId': 'a2',
          'messages': {
            'u1': {
              'id': 'u1',
              'role': 'user',
              'content': 'hi',
              'parentId': null,
              'childrenIds': ['a1', 'a2'],
            },
            'a1': {
              'id': 'a1',
              'role': 'assistant',
              'content': 'old reply',
              'parentId': 'u1',
              'childrenIds': [],
            },
            'a2': {
              'id': 'a2',
              'role': 'assistant',
              'content': 'regenerated',
              'parentId': 'u1',
              'childrenIds': [],
              'sources': [
                {'name': 'doc.pdf'},
              ],
            },
          },
        },
      },
    };

    test('thread follows currentId through the message tree', () {
      final chat = Chat.fromServer(serverJson);
      expect(chat.thread.map((m) => m.id), ['u1', 'a2']);
      expect(chat.models, ['llama3']);
    });

    test('round-trips unknown server fields so nothing is lost on save', () {
      final body = Chat.fromServer(serverJson).toServerBody();
      expect(body['params'], {'temperature': 0.2});
      final a2 = (body['history'] as Map)['messages']['a2'] as Map;
      expect(a2['sources'], [
        {'name': 'doc.pdf'},
      ]);
      expect((body['messages'] as List).length, 2);
    });

    test('append links parent and moves the tip', () {
      final chat = Chat.fromServer(serverJson);
      chat.append(
        ChatMessage(id: 'u2', role: 'user', content: 'more', parentId: 'a2'),
      );
      expect(chat.currentId, 'u2');
      expect(chat.messages['a2']!.childrenIds, ['u2']);
      expect(chat.thread.map((m) => m.id), ['u1', 'a2', 'u2']);
    });
  });

  test('parseSse yields deltas and stops at [DONE]', () async {
    const raw =
        'data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n'
        ': keep-alive\n\n'
        'data: {"choices":[{"delta":{"content":"lo"}}]}\n\n'
        'data: [DONE]\n\n'
        'data: {"choices":[{"delta":{"content":"ignored"}}]}\n\n';
    final chunks = await parseSse(Stream.value(utf8.encode(raw))).toList();
    expect(chunks.map(deltaContent).join(), 'Hello');
  });

  test('a reply saved only as output items still shows its text', () {
    final m = ChatMessage.fromJson({
      'id': 'a1',
      'role': 'assistant',
      'content': '',
      'done': true,
      'output': [
        {'type': 'function_call', 'name': 'search'},
        {
          'type': 'message',
          'content': [
            {'type': 'output_text', 'text': 'Found it.'},
          ],
        },
      ],
    });
    expect(m.content, 'Found it.');
    expect(m.done, isTrue);
    expect(m.error, isNull);
  });

  test('a failed reply exposes the server error', () {
    final m = ChatMessage.fromJson({
      'id': 'a1',
      'role': 'assistant',
      'content': '',
      'done': true,
      'error': {'content': 'Model not found'},
    });
    expect(m.error, 'Model not found');
  });

  test('siblings and the newest branch tip', () {
    final chat = Chat(id: 'c', title: 't', messages: {})
      ..append(ChatMessage(id: 'u1', role: 'user', content: 'q'))
      ..append(
        ChatMessage(id: 'a1', role: 'assistant', content: '1', parentId: 'u1'),
      );
    chat
      ..currentId = 'u1'
      ..append(
        ChatMessage(id: 'a2', role: 'assistant', content: '2', parentId: 'u1'),
      )
      ..append(
        ChatMessage(id: 'u2', role: 'user', content: 'more', parentId: 'a2'),
      );
    expect(chat.siblingsOf(chat.messages['a1']!), ['a1', 'a2']);
    expect(chat.siblingsOf(chat.messages['u1']!), ['u1']);
    expect(chat.latestUnder('a2'), 'u2');
    expect(chat.latestUnder('u1'), 'u2');
    expect(chat.latestUnder('a1'), 'a1');
  });
}
