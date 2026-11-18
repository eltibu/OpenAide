// Runs against a real Open WebUI 0.13.4 or newer; see server_sync_test.dart.
// What OpenAide does with 0.13.4: image and video connections and their
// models, chats that keep their terminal, folder statuses, the folder's
// automations, calendars that can be renamed, and the orchestrator policy
// routes that are gone.
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/api/server_version.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/admin/media_connections.dart';
import 'package:nexus_assistant/features/admin/orchestrator_policy.dart';
import 'package:nexus_assistant/features/calendar/calendar_api.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/chat/folder_board.dart';
import 'package:nexus_assistant/features/chat/media_models.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final fake =
      Platform.environment['FAKE_OPENAI_URL'] ?? 'http://127.0.0.1:11500/v1';
  var skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;
  late OpenWebUiClient client;

  setUpAll(() async {
    if (url == null) return;
    final c = OpenWebUiClient(baseUrl: url);
    final version =
        '${((await c.send('GET', '/api/version')) as Map)['version']}';
    if (!serverAtLeast(version, 0, 13, 4)) {
      skip = 'Open WebUI $version is older than 0.13.4';
    }
  });

  setUp(() async {
    if (url == null) return;
    client = OpenWebUiClient(baseUrl: url);
    await client.signIn(email!, password!);
  });

  test('image connections save and offer their models', () async {
    if (skip != null) return markTestSkipped(skip!);
    final before = (await client.send('GET', '/api/v1/images/config') as Map)
        .cast<String, dynamic>();
    expect(before.containsKey('IMAGE_CONNECTIONS'), isTrue);
    addTearDown(
      () => client.send('POST', '/api/v1/images/config/update', body: before),
    );
    final connection = newMediaConnection(MediaKind.images)
      ..['name'] = 'Test images'
      ..['url'] = fake
      ..['key'] = 'fake';
    (connection['config'] as Map)['model_ids'] = parseModelIds(
      'fake-image, fake-image-2',
    );
    final saved = await client.send(
      'POST',
      '/api/v1/images/config/update',
      body: {
        ...before,
        'ENABLE_IMAGE_GENERATION': true,
        'IMAGE_CONNECTIONS': [connection],
      },
    ) as Map;
    final back = (saved['IMAGE_CONNECTIONS'] as List).single as Map;
    expect(back['id'], connection['id']);
    expect((back['config'] as Map)['model_ids'], [
      'fake-image',
      'fake-image-2',
    ]);
    expect(isPublicMedia((back['config'] as Map)['access_grants']), isTrue);
    // The + menu's choice: one model per connection model, by reference.
    final models = parseMediaModels(
      await client.send('GET', '/api/v1/images/models'),
    );
    expect(models.map((m) => m.id), [
      '${connection['id']}:fake-image',
      '${connection['id']}:fake-image-2',
    ]);
    expect(models.first.connection, 'Test images');
  });

  test('video settings read and save, with their connections', () async {
    if (skip != null) return markTestSkipped(skip!);
    final before = (await client.send('GET', '/api/v1/videos/config') as Map)
        .cast<String, dynamic>();
    expect(before.containsKey('VIDEO_CONNECTIONS'), isTrue);
    addTearDown(
      () => client.send('POST', '/api/v1/videos/config/update', body: before),
    );
    final connection = newMediaConnection(MediaKind.videos)
      ..['url'] = fake
      ..['key'] = 'fake';
    (connection['config'] as Map)['model_ids'] = ['fake-video'];
    final saved = await client.send(
      'POST',
      '/api/v1/videos/config/update',
      body: {
        ...before,
        'ENABLE_VIDEO_GENERATION': true,
        'VIDEO_CONNECTIONS': [connection],
      },
    ) as Map;
    expect((saved['VIDEO_CONNECTIONS'] as List), hasLength(1));
    final config = await client.send('GET', '/api/config') as Map;
    expect((config['features'] as Map)['enable_video_generation'], isTrue);
    // Admins may always use it.
    final models = parseMediaModels(
      await client.send('GET', '/api/v1/videos/models'),
    );
    expect(models.single.id, '${connection['id']}:fake-video');
  });

  test('a chat keeps its terminal', () async {
    if (skip != null) return markTestSkipped(skip!);
    final chat = await client.createChat(
      Chat(id: '', title: 'Terminal chat', messages: {}, models: ['fake']),
    );
    addTearDown(() => client.deleteChat(chat.id));
    await client.patchChat(chat.id, {
      'terminal_id': 'local',
      'working_directory': '',
    });
    expect(chatTerminalChoice(await client.chat(chat.id)), 'local');
    await client.patchChat(chat.id, {'terminal_id': null});
    expect(chatTerminalChoice(await client.chat(chat.id)), '');
  });

  test('a folder sets up statuses and its chats get one', () async {
    if (skip != null) return markTestSkipped(skip!);
    final folder = await client.send(
      'POST',
      '/api/v1/folders/',
      body: {'name': 'Board ${DateTime.now().millisecondsSinceEpoch}'},
    ) as Map;
    final id = '${folder['id']}';
    addTearDown(
      () => client.send(
        'DELETE',
        '/api/v1/folders/$id',
        query: {'delete_contents': 'true'},
      ),
    );
    await client.send(
      'POST',
      '/api/v1/folders/$id/update',
      body: {
        'meta': {
          'statuses': [
            for (final s in suggestedFolderStatuses.take(3)) s.toJson(),
          ],
        },
      },
    );
    final detail = await client.send('GET', '/api/v1/folders/$id') as Map;
    expect(folderStatuses(detail).map((s) => s.id), [
      'backlog',
      'todo',
      'in_progress',
    ]);
    final chat = await client.createChat(
      Chat(id: '', title: 'Board chat', messages: {}, models: ['fake']),
    );
    await client.moveChat(chat.id, id);
    await client.send(
      'PATCH',
      '/api/v1/folders/$id/chats/${chat.id}/status',
      body: {'status': 'todo'},
    );
    final page = await client.send(
      'GET',
      '/api/v1/folders/$id/shared/chats',
      query: folderChatQuery(page: 1),
    ) as Map;
    final row = FolderChat(
      ((page['chats'] as List).single as Map).cast<String, dynamic>(),
    );
    expect(row.status, 'todo');
    expect(row.canEditStatus, isTrue);
    expect(row.statusSince, isNotNull);
    // The status filter.
    final todo = await client.send(
      'GET',
      '/api/v1/folders/$id/shared/chats',
      query: folderChatQuery(page: 1, status: 'todo'),
    ) as Map;
    expect(todo['chats'] as List, hasLength(1));
    final none = await client.send(
      'GET',
      '/api/v1/folders/$id/shared/chats',
      query: folderChatQuery(page: 1, status: 'none'),
    ) as Map;
    expect(none['chats'] as List, isEmpty);
    // Search by title.
    final found = await client.send(
      'GET',
      '/api/v1/folders/$id/shared/chats',
      query: folderChatQuery(page: 1, search: 'Board chat'),
    ) as Map;
    expect(found['chats'] as List, hasLength(1));
    // Unknown statuses are refused.
    await expectLater(
      client.send(
        'PATCH',
        '/api/v1/folders/$id/chats/${chat.id}/status',
        body: {'status': 'nope'},
      ),
      throwsA(isA<ApiException>()),
    );
    // And the folder's automations (none yet).
    expect(
      await client.send('GET', '/api/v1/folders/$id/automations'),
      isEmpty,
    );
  });

  test('a calendar can be renamed and recolored', () async {
    if (skip != null) return markTestSkipped(skip!);
    final api = CalendarApi(client);
    final name = 'Cal ${DateTime.now().millisecondsSinceEpoch}';
    await api.createCalendar(name, const Color(0xFF3B82F6));
    final made = (await api.calendars()).firstWhere((c) => c.name == name);
    addTearDown(() => api.deleteCalendar(made.id));
    await api.updateCalendar(made.id, '$name!', const Color(0xFFEF4444));
    final back = (await api.calendars()).firstWhere((c) => c.id == made.id);
    expect(back.name, '$name!');
    expect(back.color?.toARGB32(), 0xFFEF4444);
  });

  test('connections no longer keep an orchestrator policy', () async {
    if (skip != null) return markTestSkipped(skip!);
    expect(await OrchestratorPolicy.supported(client), isFalse);
  });
}
