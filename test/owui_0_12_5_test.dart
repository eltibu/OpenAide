// Open WebUI 0.12.5: note pages and their files, chat files shown with
// display_file, provider details, animated images, the Sessions explorer,
// number valves as sliders and the new Visible controls.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/analytics_sessions.dart';
import 'package:nexus_assistant/features/admin/visible_controls.dart';
import 'package:nexus_assistant/features/notes/notes_api.dart';
import 'package:nexus_assistant/features/studio/studio_api.dart';
import 'package:nexus_assistant/features/workspace/provider_details.dart';
import 'package:nexus_assistant/features/workspace/tools_skills.dart';

class _FakeClient extends OpenWebUiClient {
  _FakeClient(this.answer) : super(baseUrl: 'http://x');
  final Object? Function(String method, String path, Map<String, String>? q)
  answer;
  final calls = <(String, String, Object?, Map<String, String>?)>[];

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    calls.add((method, path, body, query));
    return answer(method, path, query);
  }
}

Map<String, dynamic> _page(
  String id,
  String title,
  String md, [
  String? parent,
]) => {
  'id': id,
  'title': title,
  'parent_id': parent,
  'content': {'json': null, 'html': '', 'md': md},
  'revision': 2,
};

void main() {
  group('note pages', () {
    final json = {
      'id': 'n1',
      'title': 'Trip',
      'updated_at': 1761850000000000000,
      'write_access': true,
      'data': {
        'content': {'md': '## Trip\n\nall pages joined'},
        'pages_revision': 4,
        'pages': [
          _page('main', 'Trip', 'Plan [ticket.pdf](/api/v1/files/f-1/content)'),
          _page('p2', 'Day 1', 'Museum'),
          _page('p3', 'Morning', 'Coffee', 'p2'),
        ],
      },
    };

    test('reads pages, their order, depth and revision', () {
      final n = Note.fromJson(json);
      expect(n.paged, isTrue);
      expect(n.pagesRevision, 4);
      expect(n.pages.map((p) => p.id), ['main', 'p2', 'p3']);
      expect(n.pages.first.isMain, isTrue);
      expect(pageDepth(n.pages, n.pages[2]), 1);
      expect(pageBranch(n.pages, 'p2'), {'p2', 'p3'});
    });

    test('a note from an older server has no pages', () {
      final n = Note.fromJson({
        'id': 'n',
        'title': 'Old',
        'data': {
          'content': {'md': 'text'},
          'files': [
            {'id': 'f', 'name': 'a.txt'},
          ],
        },
      });
      expect(n.paged, isFalse);
      expect(n.files.single['id'], 'f');
      expect(n.markdown, 'text');
    });

    test('lists show the page count', () {
      final n = Note.fromJson({
        'id': 'n',
        'title': 'x',
        'data': {
          'content': {'md': 'a'},
          'page_count': 3,
          'page_id': 'main',
        },
      });
      expect(n.pageCount, 3);
    });

    test('files live as links in the page', () {
      const md = 'Plan [ticket.pdf](/api/v1/files/f-1/content)';
      expect(pageFiles(md).single, {
        'type': 'file',
        'id': 'f-1',
        'name': 'ticket.pdf',
      });
      final added = withFileLink(md, {'id': 'f-2', 'name': 'map [v2].png'});
      expect(added, endsWith('\n\n[map v2.png](/api/v1/files/f-2/content)'));
      expect(pageFiles(added).map((f) => f['id']), ['f-1', 'f-2']);
      expect(withoutFileLink(added, 'f-2'), md);
      expect(withoutFileLink(added, 'f-1'), contains('f-2'));
      expect(pageFiles(withoutFileLink(added, 'f-1')).single['id'], 'f-2');
      expect(
        withFileLink('', {'id': 'x', 'name': 'a'}),
        '[a](/api/v1/files/x/content)',
      );
    });

    test('saves a page with its page id and changes pages', () async {
      final client = _FakeClient((m, p, q) => json);
      final api = NotesApi(client);
      await api.update('n1', title: 'Trip', markdown: 'hi', pageId: 'p2');
      final (_, path, body, _) = client.calls.last;
      expect(path, '/api/v1/notes/n1/update');
      expect((body as Map)['page_id'], 'p2');
      expect(body['data']['content']['md'], 'hi');
      expect(body['data'].containsKey('files'), isFalse);

      // A title alone sends no page.
      await api.update('n1', title: 'T');
      expect((client.calls.last.$3 as Map).containsKey('page_id'), isFalse);

      final n = await api.pages(
        'n1',
        'create',
        revision: 4,
        newId: 'new',
        parentId: 'p2',
        title: 'Lunch',
      );
      expect(n.pages, hasLength(3));
      final (_, p2, b2, _) = client.calls.last;
      expect(p2, '/api/v1/notes/n1/pages/update');
      expect(b2, {
        'action': 'create',
        'revision': 4,
        'new_id': 'new',
        'parent_id': 'p2',
        'title': 'Lunch',
      });

      // Moving to the top level sends parent_id null on purpose.
      await api.pages('n1', 'move', revision: 4, pageId: 'p3', toTop: true);
      final b3 = client.calls.last.$3 as Map;
      expect(b3.containsKey('parent_id'), isTrue);
      expect(b3['parent_id'], isNull);
    });

    test('a Studio document is the main page', () {
      final d = StudioDocument.fromJson(json);
      expect(d.markdown, startsWith('Plan'));
    });
  });

  test('chat files shown with display_file come in the reply', () {
    final m = ChatMessage.fromJson({
      'id': 'r',
      'role': 'assistant',
      'content': 'Here',
      'output': [
        {
          'type': 'function_call',
          'call_id': 'c1',
          'name': 'display_file',
          'arguments': '{"path":"f-9"}',
        },
        {
          'type': 'function_call_output',
          'call_id': 'c1',
          'output': [
            {
              'type': 'input_text',
              'text': jsonEncode({
                'type': 'file',
                'source': 'open_webui',
                'exists': true,
                'path': '/api/v1/files/f-9/content',
                'full_path': '/api/v1/files/f-9/content',
                'name': 'photo.jpg',
                'content_type': 'image/jpeg',
              }),
            },
          ],
        },
        {
          'type': 'function_call',
          'call_id': 'c2',
          'name': 'display_file',
          'arguments': '{"path":"nope"}',
        },
        {
          'type': 'function_call_output',
          'call_id': 'c2',
          'output': [
            {
              'type': 'input_text',
              'text': '{"error": "File not found", "exists": false}',
            },
          ],
        },
      ],
    });
    final a = m.attachments.single;
    expect(a.isImage, isTrue);
    expect(a.fileId, 'f-9');
    expect(a.name, 'photo.jpg');
    // The same file marked as a terminal's keeps its server path.
    expect(
      ChatMessage.terminalFile({
        'type': 'file',
        'source': 'open_terminal',
        'terminal_id': 't',
        'path': '/api/v1/files/f-9/content',
        'content_type': 'application/pdf',
      }),
      containsPair('id', 'f-9'),
    );
  });

  test('provider details from /api/models', () {
    final i = providerInfo({
      'id': 'm',
      'openai': {
        'context_length': 200000,
        'architecture': {
          'input_modalities': ['text', 'image', 'text'],
          'output_modalities': ['text'],
        },
        'top_provider': {
          'context_length': 128000,
          'max_completion_tokens': 8192,
        },
        'supported_parameters': ['temperature', 'tools'],
      },
    });
    expect(i.inputs, ['text', 'image']);
    expect(i.context, 200000);
    expect(i.providerContext, 128000);
    expect(i.maxOutput, 8192);
    expect(i.parameters, ['temperature', 'tools']);
    expect(providerInfoAvailable(providerInfo({'id': 'x'})), isFalse);
  });

  testWidgets('provider details show what the provider reports', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: nexusTheme(Brightness.light),
        home: Scaffold(
          body: ProviderDetails(
            entry: {
              'context_length': 32000,
              'architecture': {
                'input_modalities': ['text', 'image'],
              },
            },
          ),
        ),
      ),
    );
    expect(find.text('Provider details'), findsOneWidget);
    await t.tap(find.text('Provider details'));
    await t.pumpAndSettle();
    expect(find.text('Text, Image'), findsOneWidget);
    expect(find.text('32,000 tokens'), findsOneWidget);
    expect(find.text('Not provided'), findsWidgets);
  });

  test('animated WebP and PNG images keep all their frames', () async {
    for (final f in ['animated.webp', 'animated.png']) {
      final bytes = File('test/fixtures/$f').readAsBytesSync();
      final codec = await ui.instantiateImageCodec(bytes);
      expect(codec.frameCount, 3, reason: f);
    }
  });

  test('session spans read like the web', () {
    expect(sessionSpan(null), '–');
    expect(sessionSpan(42), '42s');
    expect(sessionSpan(192), '3m 12s');
    expect(sessionSpan(7260), '2h 1m');
    expect(sessionTokenRanges, hasLength(6));
  });

  testWidgets('Sessions list, filters by tokens, and opens a session', (
    t,
  ) async {
    t.view.physicalSize = const Size(1080, 2800);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final client = _FakeClient((m, p, q) {
      if (p == '/api/v1/analytics/sessions') {
        return {
          'items': [
            {
              'id': 'c1',
              'title': 'Plan trip',
              'user_name': 'Joel',
              'model_id': 'nexus',
              'model_count': 1,
              'tokens': 1500,
              'recorded_responses': 2,
              'responses': 2,
              'errors': 1,
              'span_seconds': 75,
            },
          ],
          'has_more': false,
          if (q?['include_summary'] == 'true')
            'overview': {
              'sessions': 1,
              'tokens': 1500,
              'responses': 2,
              'errors': 1,
              'token_distribution': [0, 0, 1, 0, 0, 0],
            },
        };
      }
      if (p.endsWith('/events')) {
        return {
          'items': [
            {
              'type': 'function_call',
              'name': 'search_web',
              'status': 'completed',
              'duration_seconds': 1.25,
              'details': '{"query":"rome"}',
            },
          ],
          'has_more': false,
        };
      }
      return {
        'session': {'user_name': 'Joel', 'tokens': 1500, 'responses': 2},
        'items': [
          {'id': 'u', 'role': 'user', 'preview': 'Plan a trip'},
          {
            'id': 'a',
            'role': 'assistant',
            'preview': 'Sure',
            'model_id': 'nexus',
            'tokens': 900,
            'output_count': 2,
          },
        ],
        'has_more': false,
      };
    });
    await t.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const AnalyticsSessionsScreen(range: {'start_date': '1'}),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Plan trip'), findsOneWidget);
    expect(find.text('1500 tok'), findsOneWidget);
    expect(client.calls.first.$4, containsPair('start_date', '1'));
    expect(client.calls.first.$4, containsPair('include_summary', 'true'));

    await t.tap(find.textContaining('1k–10k'));
    await t.pumpAndSettle();
    expect(client.calls.last.$4, containsPair('token_min', '1000'));
    expect(client.calls.last.$4, containsPair('token_max', '10000'));

    await t.tap(find.text('Plan trip'));
    await t.pumpAndSettle();
    expect(client.calls.last.$2, '/api/v1/analytics/sessions/c1');
    expect(find.text('Sure'), findsOneWidget);
    await t.tap(find.text('Sure'));
    await t.pumpAndSettle();
    expect(
      client.calls.last.$2,
      '/api/v1/analytics/sessions/c1/messages/a/events',
    );
    expect(find.text('search_web'), findsOneWidget);
    expect(find.textContaining('1.3s'), findsOneWidget);
  });

  testWidgets('Sessions explains when admin chat access is off', (t) async {
    final client = _FakeClient(
      (m, p, q) => throw ApiException(403, 'Admin chat access is disabled'),
    );
    await t.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const AnalyticsSessionsScreen(),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('ENABLE_ADMIN_CHAT_ACCESS'), findsOneWidget);
  });

  testWidgets('a number valve with input range is a slider', (t) async {
    final client = _FakeClient((m, p, q) {
      if (p.endsWith('/spec')) {
        return {
          'properties': {
            'level': {
              'title': 'Level',
              'type': 'integer',
              'default': 3,
              'minimum': 0,
              'maximum': 10,
              'input': {'type': 'range'},
            },
          },
        };
      }
      return {'level': 4};
    });
    await t.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const ValvesScreen(
            title: 'Valves',
            specPath: '/v/spec',
            valuesPath: '/v',
            savePath: '/v/update',
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final slider = t.widget<Slider>(find.byType(Slider));
    expect(slider.min, 0);
    expect(slider.max, 10);
    expect(slider.value, 4);
    expect(slider.divisions, 10);
    await t.drag(find.byType(Slider), const Offset(-2000, 0));
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextField, '0'), findsOneWidget);
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(client.calls.last.$3, {'level': 0});
  });

  test('the chat box choices are in Visible controls', () {
    final ids = [
      for (final (prefix, _, items) in visibleControlGroups)
        for (final (id, _) in items) '$prefix$id',
    ];
    for (final id in [
      'chat.selected_tools',
      'chat.selected_skills',
      'chat.selected_filters',
      'chat.selected_web_search',
      'chat.selected_image_generation',
      'chat.selected_code_interpreter',
    ]) {
      expect(ids, contains(id));
    }
  });
}
