// Runs against a real Open WebUI server; see tool_approval_test.dart. Your
// own tool server is a small OpenAPI server the test starts; the fake model
// calls its get_weather for "weather", and the server asks this "phone" to
// run it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/settings/tool_servers.dart';

class _Session extends SessionNotifier {
  _Session(this.session);
  final Session session;
  @override
  Future<Session?> build() async => session;
}

const _spec = {
  'openapi': '3.1.0',
  'info': {'title': 'Weather', 'description': 'Forecasts'},
  'paths': {
    '/weather/{unit}': {
      'parameters': [
        {
          'name': 'unit',
          'in': 'path',
          'required': true,
          'schema': {'type': 'string'},
        },
      ],
      'post': {
        'operationId': 'get_weather',
        'summary': 'Weather in a city',
        'parameters': [
          {
            'name': 'days',
            'in': 'query',
            'schema': {
              'type': 'integer',
              'enum': [1, 2],
            },
          },
        ],
        'requestBody': {
          'content': {
            'application/json': {
              'schema': {r'$ref': '#/components/schemas/Where'},
            },
          },
        },
      },
    },
  },
  'components': {
    'schemas': {
      'Where': {
        'type': 'object',
        'properties': {
          'city': {'type': 'string', 'description': 'City name'},
        },
        'required': ['city'],
      },
    },
  },
};

Future<HttpServer> _serve(List<String> seen) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final body = await utf8.decodeStream(req);
    seen.add(
      '${req.method} ${req.uri} ${req.headers.value('authorization')} $body',
    );
    req.response.headers.contentType = ContentType.json;
    if (req.uri.path == '/openapi.json') {
      req.response.write(jsonEncode(_spec));
    } else if (req.uri.path.startsWith('/weather/')) {
      req.response.write(jsonEncode({'forecast': 'Sunny in Paris'}));
    } else {
      req.response.statusCode = 404;
    }
    await req.response.close();
  });
  return server;
}

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'OpenAPI operations become tools, and calls split their params',
    () async {
      final tools = openApiTools(_spec);
      expect(tools.single['name'], 'get_weather');
      expect(tools.single['description'], 'Weather in a city');
      final params = tools.single['parameters'] as Map;
      expect((params['properties'] as Map).keys, ['unit', 'days', 'city']);
      expect(params['required'], ['unit', 'city']);
      expect(
        ((params['properties'] as Map)['days'] as Map)['description'],
        '. Possible values: 1, 2',
      );

      HttpOverrides.global = null;
      final seen = <String>[];
      final server = await _serve(seen);
      addTearDown(server.close);
      final base = 'http://127.0.0.1:${server.port}';
      final res = await runToolServer('k', base, 'get_weather', {
        'unit': 'c',
        'days': 2,
        'city': 'Paris',
      }, _spec);
      expect(res.first, {'forecast': 'Sunny in Paris'});
      expect(seen.single, 'POST /weather/c?days=2 Bearer k {"city":"Paris"}');
      final missing = await runToolServer(null, base, 'nope', {}, _spec);
      expect((missing.first as Map)['error'], contains('No matching route'));
    },
  );

  test('a chat uses your own tool server through the phone', () async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    final seen = <String>[];
    final tools = await _serve(seen);
    addTearDown(tools.close);
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final before = await client.send('GET', '/api/v1/configs/connections');
    await client.send(
      'POST',
      '/api/v1/configs/connections',
      body: {...before as Map, 'ENABLE_DIRECT_INTEGRATIONS': true},
    );
    final settings = await client.userSettings();
    final ui = Map<String, dynamic>.of((settings['ui'] as Map?)?.cast() ?? {});
    final saved = ui[userToolServersKey];
    ui[userToolServersKey] = [
      {
        'type': 'openapi',
        'url': 'http://127.0.0.1:${tools.port}',
        'path': 'openapi.json',
        'spec_type': 'url',
        'auth_type': 'bearer',
        'key': 'secret',
        'config': {'enable': true},
        'info': {'name': 'Weather'},
      },
    ];
    await client.send(
      'POST',
      '/api/v1/users/user/settings/update',
      body: {...settings, 'ui': ui},
    );
    addTearDown(() async {
      if (saved == null) {
        ui.remove(userToolServersKey);
      } else {
        ui[userToolServersKey] = saved;
      }
      await client.send(
        'POST',
        '/api/v1/users/user/settings/update',
        body: {...settings, 'ui': ui},
      );
      await client.send('POST', '/api/v1/configs/connections', body: before);
    });

    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(
          () => _Session(Session(serverUrl: url, token: client.token!)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    final picker = await container.read(chatToolsProvider.future);
    final mine = picker.firstWhere((p) => p.id == '${directServerPrefix}0');
    expect(mine.name, 'Weather');
    final models = await container.read(modelsProvider.future);

    // ServerAsks answers execute:tool in the app; here the test wires the
    // same handler.
    final socket = container.read(chatSocketProvider);
    await socket.ready(timeout: const Duration(seconds: 10));
    final sub = socket.calls.listen((c) {
      if (c.type == 'execute:tool') {
        answerExecuteTool(
          c,
          ui: ui,
          sessionToken: client.token,
          data: container.read(userToolServersDataProvider).value ?? const [],
        );
      } else {
        c.reply(true);
      }
    });
    addTearDown(sub.cancel);

    final controller = container.read(chatControllerProvider.notifier)
      ..selectModel(models.first.id)
      ..newChat(temporary: true)
      ..setTool(mine.id, true);
    await controller.send("What's the weather?");
    await Future<void>.delayed(const Duration(milliseconds: 100));
    for (var i = 0; i < 300; i++) {
      if (!container.read(chatControllerProvider).streaming) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(seen.any((s) => s.startsWith('POST /weather/')), isTrue);
    expect(
      container.read(chatControllerProvider).messages.last.content,
      contains('Sunny in Paris'),
    );
  }, skip: skip);
}
