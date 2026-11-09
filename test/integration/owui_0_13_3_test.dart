// Runs against a real Open WebUI 0.13.3 or newer; see server_sync_test.dart.
// What OpenAide does with 0.13.3: a terminal's coding agents for an
// automation, the server's checks on an automation's terminal and agent,
// and agents refused as saved models.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/automations/automations_api.dart';
import 'package:nexus_assistant/features/workspace/models_api.dart';

/// 0.13.3 or newer.
bool _atLeast0133(String version) {
  final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(version);
  if (m == null) return true;
  final v = [for (var i = 1; i <= 3; i++) int.parse(m[i]!)];
  if (v[0] != 0) return v[0] > 0;
  if (v[1] != 13) return v[1] > 13;
  return v[2] >= 3;
}

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
    if (!_atLeast0133(version)) {
      skip = 'Open WebUI $version is older than 0.13.3';
    }
  });

  setUp(() async {
    if (url == null) return;
    client = OpenWebUiClient(baseUrl: url);
    await client.signIn(email!, password!);
  });

  Map<String, dynamic> form(String model, {Map? terminal, Map? target}) => {
    'name': 'nexus agent auto',
    'data': {
      'prompt': 'Say hi',
      'model_id': model,
      'rrule': Schedule(frequency: 'DAILY', hour: 4).build(),
      'target': target ?? {'type': 'chat'},
      'terminal': ?terminal,
    },
    'is_active': false,
  };

  test('a terminal lists its coding agents for an automation', () async {
    if (skip != null) return markTestSkipped(skip!);
    final api = AutomationsApi(client);
    // The test terminal has no agents installed: an empty list, no error.
    final agents = await api.agentModels('local', cwd: '/tmp');
    expect(agents.every((m) => m.isAgent), isTrue);
    // Straight from the server too, so a missing endpoint can't hide.
    final raw = await client.send(
      'GET',
      '/api/v1/automations/models',
      query: {'terminal_id': 'local'},
    );
    expect(raw, isA<List>());
  }, skip: url == null);

  test('the server checks an automation\'s terminal and agent', () async {
    if (skip != null) return markTestSkipped(skip!);
    final api = AutomationsApi(client);
    final models =
        ((await client.send('GET', '/api/models')) as Map)['data'] as List;
    final model = '${models.first['id']}';

    // A terminal it can't reach is refused.
    await expectLater(
      api.save(null, form(model, terminal: {'server_id': 'nowhere'})),
      throwsA(isA<ApiException>()),
    );
    // An agent needs a terminal, ...
    await expectLater(
      api.save(null, form('agent:local:claude:sonnet')),
      throwsA(isA<ApiException>()),
    );
    // ... one that offers it, ...
    await expectLater(
      api.save(
        null,
        form('agent:local:claude:sonnet', terminal: {'server_id': 'local'}),
      ),
      throwsA(isA<ApiException>()),
    );
    // ... and replies into a chat, never a channel.
    await expectLater(
      api.save(
        null,
        form(
          'agent:local:claude:sonnet',
          terminal: {'server_id': 'local'},
          target: {'type': 'channel', 'channel_id': 'x'},
        ),
      ),
      throwsA(isA<ApiException>()),
    );

    // An ordinary model with a reachable terminal and folder is fine.
    final a = await api.save(
      null,
      form(model, terminal: {'server_id': 'local', 'cwd': '/tmp'}),
    );
    try {
      expect(a.terminalId, 'local');
      expect(a.cwd, '/tmp');
      expect(a.isAgent, isFalse);
    } finally {
      await api.delete(a.id);
    }
  }, skip: url == null);

  test('a terminal agent can\'t be saved as a model', () async {
    if (skip != null) return markTestSkipped(skip!);
    final api = ModelsApi(client);
    Map<String, dynamic> model(String id, String? base) => {
      'id': id,
      'name': 'nexus agent model',
      'base_model_id': base,
      'meta': <String, dynamic>{},
      'params': <String, dynamic>{},
    };
    await expectLater(
      api.save(model('agent:local:claude:sonnet', null), create: true),
      throwsA(isA<ApiException>()),
    );
    await expectLater(
      api.save(
        model('nexus-on-agent', 'agent:local:claude:sonnet'),
        create: true,
      ),
      throwsA(isA<ApiException>()),
    );
  }, skip: url == null);
}
