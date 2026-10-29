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

  test('tool calls and sources come from the saved reply', () {
    final m = ChatMessage.fromJson({
      'id': 'a1',
      'role': 'assistant',
      'content': 'Done.',
      'output': [
        {
          'type': 'function_call',
          'call_id': 'c1',
          'name': 'get_time',
          'arguments': '{}',
        },
        {
          'type': 'function_call_output',
          'call_id': 'c1',
          'output': [
            {'type': 'input_text', 'text': '12:00'},
          ],
        },
      ],
      'sources': [
        {
          'source': {'name': 'web'},
          'metadata': [
            {'source': 'https://example.com', 'title': 'Example'},
            {'source': 'https://example.com', 'title': 'Example'},
          ],
        },
      ],
    });
    expect(m.toolCalls.single.name, 'get_time');
    expect(m.toolCalls.single.result, '12:00');
    expect(m.sources.single.name, 'Example');
    expect(m.sources.single.url, 'https://example.com');
  });

  test('saving keeps images and other non-text parts of a message', () {
    final parts = [
      {'type': 'text', 'text': 'What is this?'},
      {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,AAAA'},
      },
    ];
    final m = ChatMessage.fromJson({
      'id': 'u1',
      'role': 'user',
      'content': parts,
    });
    expect(m.content, 'What is this?');
    expect(m.toJson()['content'], parts);
  });

  test('attachments use the web UI shape and tell photos from files', () {
    final photo = Attachment.uploaded({
      'id': 'f1',
      'filename': 'dot.png',
      'meta': {'name': 'dot.png', 'content_type': 'image/png'},
    }, size: 68);
    expect(photo.toJson(), containsPair('url', 'f1'));
    expect(photo.toJson(), containsPair('type', 'file'));
    expect(photo.isImage, isTrue);
    expect(photo.fileId, 'f1');

    final m = ChatMessage.fromJson({
      'id': 'u',
      'role': 'user',
      'content': 'look',
      'files': [
        photo.toJson(),
        {'type': 'image', 'url': 'data:image/png;base64,AAAA'},
        {
          'type': 'file',
          'id': 'f2',
          'url': 'f2',
          'name': 'logo.svg',
          'content_type': 'image/svg+xml',
        },
      ],
    });
    final a = m.attachments;
    expect(a.map((x) => x.isImage), [true, true, false]);
    expect(a[1].dataUrl, startsWith('data:'));
    expect(a[1].fileId, isNull);
    expect(m.toJson()['files'], hasLength(3));
  });

  test('pictures tools showed: tool files and terminal display_file', () {
    final m = ChatMessage.fromJson({
      'id': 'r',
      'role': 'assistant',
      'content': 'Here it is',
      'output': [
        {
          'type': 'function_call',
          'call_id': 'c1',
          'name': 'display_file',
          'arguments': '{"path":"chart.png","inline":true}',
        },
        {
          'type': 'function_call_output',
          'call_id': 'c1',
          'output': [
            {
              'type': 'input_text',
              'text': jsonEncode({
                'type': 'file',
                'source': 'open_terminal',
                'terminal_id': 'term 1',
                'path': 'chart.png',
                'full_path': '/home/user/chart.png',
                'name': 'chart.png',
                'content_type': 'image/png',
              }),
            },
          ],
        },
        {
          'type': 'function_call',
          'call_id': 'c2',
          'name': 'share_file',
          'arguments': '{}',
        },
        {
          'type': 'function_call_output',
          'call_id': 'c2',
          'output': [
            {'type': 'input_text', 'text': 'shared'},
          ],
          'files': [
            {'type': 'image', 'url': '/api/v1/files/abc/content'},
          ],
        },
      ],
    });
    final a = m.attachments;
    expect(a, hasLength(2));
    expect(a[0].isImage, isTrue);
    expect(
      a[0].serverPath,
      '/api/v1/terminals/term%201/files/view?path=%2Fhome%2Fuser%2Fchart.png',
    );
    expect(a[1].fileId, 'abc');
  });
}
