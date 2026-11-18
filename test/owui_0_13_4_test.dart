// Open WebUI 0.13.4: live updates as typed `events`, image and video
// connections and models, agent replies that can be regenerated, chats that
// keep their terminal, queued messages, folder statuses and automations,
// chat mentions in the inbox and opt-in Visualizations.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/chat_socket.dart';
import 'package:nexus_assistant/core/api/server_version.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/core/models/model_info.dart';
import 'package:nexus_assistant/features/admin/media_connections.dart';
import 'package:nexus_assistant/features/admin/orchestrator_policy.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/chat/folder_board.dart';
import 'package:nexus_assistant/features/chat/media_models.dart';
import 'package:nexus_assistant/features/chat/request_options.dart';
import 'package:nexus_assistant/features/inbox/inbox.dart';
import 'package:nexus_assistant/features/workspace/models_api.dart';

void main() {
  group('server version', () {
    test('compares versions', () {
      expect(serverAtLeast('0.13.4', 0, 13, 4), isTrue);
      expect(serverAtLeast('0.13.10', 0, 13, 4), isTrue);
      expect(serverAtLeast('0.14.0', 0, 13, 4), isTrue);
      expect(serverAtLeast('1.0.0', 0, 13, 4), isTrue);
      expect(serverAtLeast('0.13.3', 0, 13, 4), isFalse);
      expect(serverAtLeast('0.12.9', 0, 13, 4), isFalse);
      expect(serverAtLeast('v0.13.4-dev', 0, 13, 4), isTrue);
    });

    test('an unknown version counts as new', () {
      expect(serverAtLeast(null, 0, 13, 4), isTrue);
      expect(serverAtLeast('dev', 0, 13, 4), isTrue);
      expect(isOwui0134(null), isTrue);
      expect(isOwui0134({'version': '0.13.3'}), isFalse);
      expect(isOwui0134({'version': '0.13.4'}), isTrue);
    });
  });

  group('typed socket events', () {
    test('notes, comments, inbox and access arrive on events', () {
      final note = typedSocketEvent({
        'data': {
          'type': 'note:updated',
          'data': {'id': 'n1', 'updated_at': 1},
        },
      });
      expect(note?.$1, 'note:updated');
      expect(note?.$2, {'id': 'n1', 'updated_at': 1});
      expect(
        typedSocketEvent({
          'data': {'type': 'notifications:changed'},
        }),
        ('notifications:changed', null),
      );
      expect(
        typedSocketEvent({
          'data': {'type': 'access:updated'},
        })?.$1,
        'access:updated',
      );
      expect(
        typedSocketEvent({
          'data': {
            'type': 'encryption:available',
            'data': {'channel': 'c1', 'session': 's'},
          },
        })?.$2,
        {'channel': 'c1', 'session': 's'},
      );
    });

    test('chat reply events stay with the chat', () {
      expect(
        typedSocketEvent({
          'chat_id': 'c1',
          'message_id': 'm1',
          'data': {'type': 'note:updated', 'data': {}},
        }),
        isNull,
      );
      expect(
        typedSocketEvent({
          'data': {'type': 'chat:completion', 'data': {}},
        }),
        isNull,
      );
      expect(typedSocketEvent({'data': 'x'}), isNull);
    });
  });

  group('image and video models', () {
    test('the server list becomes models', () {
      final models = parseMediaModels([
        {
          'id': 'c1:gpt-image-2',
          'name': 'gpt-image-2',
          'model': 'gpt-image-2',
          'connection_id': 'c1',
          'connection_name': 'OpenAI',
          'image_generation': true,
          'image_edit': true,
        },
        {
          'id': 'c2:',
          'name': 'ComfyUI',
          'connection_name': 'ComfyUI',
          'image_generation': false,
          'image_edit': true,
        },
        {'name': 'no id'},
      ]);
      expect(models.map((m) => m.id), ['c1:gpt-image-2', 'c2:']);
      expect(models.first.label, 'gpt-image-2 (OpenAI)');
      expect(models.last.label, 'ComfyUI');
      expect(models.last.generate, isFalse);
      expect(models.first.edit, isTrue);
      expect(parseMediaModels(null), isEmpty);
    });

    test('video is only offered with a video model', () {
      expect(mediaFeatureUsable('video_generation', const []), isFalse);
      expect(
        mediaFeatureUsable('video_generation', const [
          MediaModel(id: 'v:sora', name: 'sora'),
        ]),
        isTrue,
      );
      expect(mediaFeatureUsable('image_generation', const []), isTrue);
    });

    test('a picked model rides on its feature', () {
      final model = ModelInfo.fromJson({
        'id': 'm',
        'info': {
          'meta': {
            'capabilities': {
              'image_generation': true,
              'video_generation': true,
            },
          },
        },
      });
      final config = {
        'features': {
          'enable_image_generation': true,
          'enable_video_generation': true,
        },
      };
      expect(availableFeatures(model, config), [
        'image_generation',
        'video_generation',
      ]);
      final options = requestOptions(
        model,
        null,
        config,
        overrides: {'image_generation': true, 'video_generation': true},
        mediaModels: {'image_generation': 'c1:gpt-image-2'},
      );
      final features = options['features'] as Map;
      expect(features['image_generation'], {'model': 'c1:gpt-image-2'});
      expect(features['video_generation'], isTrue);
      // A pick for a feature that's off is not sent.
      final off = requestOptions(
        model,
        null,
        config,
        mediaModels: {'image_generation': 'c1:gpt-image-2'},
      );
      expect((off['features'] as Map).containsKey('image_generation'), false);
    });

    test('video needs the admin switch', () {
      final model = ModelInfo.fromJson({'id': 'm'});
      expect(
        availableFeatures(model, {
          'features': {'enable_video_generation': false},
        }),
        isEmpty,
      );
    });
  });

  group('image and video connections', () {
    test('a new connection is open to everyone', () {
      final c = newMediaConnection(MediaKind.images);
      expect(c['id'], isNotEmpty);
      final config = c['config'] as Map;
      expect(isPublicMedia(config['access_grants']), isTrue);
      expect(config['capabilities'], {
        'image_generation': true,
        'image_edit': true,
      });
      final v = newMediaConnection(MediaKind.videos);
      expect((v['config'] as Map)['provider'], '');
      expect((v['config'] as Map).containsKey('capabilities'), isFalse);
    });

    test('model ids are a list without repeats', () {
      expect(parseModelIds('a, b\nc,, a '), ['a', 'b', 'c']);
      expect(parseModelIds(''), isEmpty);
    });

    test('the list says what each connection is', () {
      expect(
        mediaConnectionSummary({
          'type': 'comfyui',
          'url': 'http://comfy:8188',
          'config': {
            'model_ids': ['sdxl'],
            'access_grants': publicMediaGrants,
          },
        }),
        'ComfyUI · http://comfy:8188 · sdxl',
      );
      expect(
        mediaConnectionSummary({
          'type': 'openai',
          'url': '',
          'config': {
            'enable': false,
            'model_ids': ['a', 'b'],
            'access_grants': [],
          },
        }),
        'OpenAI compatible · 2 models · off · admins only',
      );
    });
  });

  group('built-in tools', () {
    test('Visualizations is off until switched on', () {
      expect(builtinToolOn({}, 'visualizations'), isFalse);
      expect(builtinToolOn({'visualizations': true}, 'visualizations'), true);
      expect(builtinToolOn({}, 'memory'), isTrue);
      expect(builtinToolOn({'memory': false}, 'memory'), isFalse);
    });

    test('tools are offered by what the server knows', () {
      expect(builtinToolOffered(null, {}), isTrue);
      expect(builtinToolOffered('enable_notes', {'enable_notes': true}), true);
      expect(builtinToolOffered('enable_notes', {}), isFalse);
      // Visualizations only needs a 0.13.4 server, whatever video says.
      expect(
        builtinToolOffered('?enable_video_generation', {
          'enable_video_generation': false,
        }),
        isTrue,
      );
      expect(builtinToolOffered('?enable_video_generation', {}), isFalse);
      expect(
        builtinToolList.any(
          (t) =>
              t.$1 == 'video_generation' && t.$3 == 'enable_video_generation',
        ),
        isTrue,
      );
    });
  });

  group('chats', () {
    test('a chat brings back its own terminal', () {
      Chat chat(Map<String, dynamic> body) =>
          Chat.fromServer({'id': 'c', 'title': 't', 'chat': body});
      expect(chatTerminalChoice(chat({})), isNull);
      expect(chatTerminalChoice(chat({'terminal_id': null})), '');
      expect(chatTerminalChoice(chat({'terminal_id': 'local'})), 'local');
    });

    test('a queued message is answered once its reply is done', () {
      final chat = Chat(
        id: 'c',
        title: 't',
        messages: {'u2': ChatMessage(id: 'u2', role: 'user', content: 'hi')},
      );
      expect(queuedAnswered(chat, 'u2'), isFalse);
      chat.messages['r2'] = ChatMessage(
        id: 'r2',
        role: 'assistant',
        content: '',
        parentId: 'u2',
      );
      expect(queuedAnswered(chat, 'u2'), isFalse);
      chat.messages['r2'] = ChatMessage(
        id: 'r2',
        role: 'assistant',
        content: 'Hello',
        parentId: 'u2',
        extra: {'done': true},
      );
      expect(queuedAnswered(chat, 'u2'), isTrue);
    });

    test('generated videos play in the chat', () {
      expect(
        Attachment.fromJson({
          'type': 'video',
          'url': '/api/v1/files/f1/content',
        }).isVideo,
        isTrue,
      );
    });
  });

  group('folders', () {
    test('statuses come from the folder, in order and without repeats', () {
      final statuses = folderStatuses({
        'meta': {
          'statuses': [
            {'id': 'todo', 'name': 'To do', 'color': 'gray'},
            {'id': 'doing', 'name': 'Doing', 'color': 'nope', 'icon': '🔥'},
            {'id': 'todo', 'name': 'Again'},
            {'id': 'none', 'name': 'No'},
            {'name': 'no id'},
          ],
        },
      });
      expect(statuses.map((s) => s.id), ['todo', 'doing']);
      expect(statuses.last.color, 'gray');
      expect(statuses.last.icon, '🔥');
      expect(folderStatuses(null), isEmpty);
      expect(statuses.first.toJson(), {
        'id': 'todo',
        'name': 'To do',
        'glyph': 'todo',
        'color': 'gray',
      });
      expect(suggestedFolderStatuses.map((s) => s.id), [
        'backlog',
        'todo',
        'in_progress',
        'waiting',
        'done',
      ]);
    });

    test('time in a status reads like the web', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000000000 * 1000);
      expect(timeInStatus(1000000000 - 3 * 86400, now: now), '3 days');
      expect(timeInStatus(1000000000 - 3600, now: now), '1 hour');
      expect(timeInStatus(1000000000 - 300, now: now), '5 minutes');
      expect(timeInStatus(1000000000 - 30, now: now), 'a few minutes');
      expect(timeInStatus(null), '');
    });

    test('the chat list asks for the folder page view', () {
      expect(folderChatQuery(page: 2, search: ' plan ', status: 'todo'), {
        'workspace': 'true',
        'page': '2',
        'sort_by': 'updated_at',
        'sort_dir': 'desc',
        'search': 'plan',
        'status': 'todo',
      });
      expect(folderChatQuery(page: 1).containsKey('search'), isFalse);
    });

    test('an automation line says its state and last run', () {
      expect(
        folderAutomationSummary({
          'is_active': false,
          'last_run': {'status': 'success'},
          'user_name': 'Joel',
        }),
        'Paused · last run success · by Joel',
      );
      expect(folderAutomationSummary({'is_active': true}), 'On');
    });
  });

  test('a mention in a chat shows in the inbox', () {
    final item = InboxItem({
      'event_type': 'chat.mentioned',
      'actor': {'name': 'Sam'},
      'resource_type': 'chat',
      'object_type': 'chat_message',
    });
    expect(item.label, 'Sam mentioned you');
  });

  test('a gone orchestrator policy route is told from a missing policy', () {
    expect(OrchestratorPolicy.policyRouteGone(405), isTrue);
    expect(OrchestratorPolicy.policyRouteGone(404), isTrue);
    expect(OrchestratorPolicy.policyRouteGone(422), isFalse);
  });
}
