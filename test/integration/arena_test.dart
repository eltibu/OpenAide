// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/admin/arena_screen.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('an arena model keeps what it picks from', () {
    final all = arenaModel(
      id: 'arena',
      name: 'Arena',
      meta: {'i18n': {}},
      description: ' ',
      image: null,
      modelIds: [],
      filterMode: 'exclude',
    );
    final meta = all['meta'] as Map;
    expect(meta['model_ids'], isNull);
    expect(meta['filter_mode'], isNull);
    expect(meta['description'], isNull);
    expect(meta['i18n'], {});
    expect(arenaPicksFrom(meta, {}), 'All models');
    expect(
      arenaPicksFrom(
        {
          'model_ids': ['a', 'b'],
          'filter_mode': 'exclude',
        },
        {'a': 'Alpha'},
      ),
      'All but Alpha, b',
    );
    expect(
      arenaPicksFrom(
        {
          'model_ids': ['a'],
          'filter_mode': 'include',
        },
        {'a': 'Alpha'},
      ),
      'Alpha',
    );
  });

  test('arena models are saved on the server', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final before =
        await client.send('GET', '/api/v1/evaluations/config') as Map;
    addTearDown(
      () => client.send('POST', '/api/v1/evaluations/config', body: before),
    );
    final model = arenaModel(
      id: 'nexus-arena',
      name: 'Nexus Arena',
      meta: {},
      description: 'blind',
      image: null,
      modelIds: ['tiny:latest'],
      filterMode: 'include',
    );
    final saved = await client.send(
      'POST',
      '/api/v1/evaluations/config',
      body: {
        'ENABLE_EVALUATION_ARENA_MODELS': true,
        'EVALUATION_ARENA_MODELS': [model],
      },
    ) as Map;
    expect(saved['ENABLE_EVALUATION_ARENA_MODELS'], isTrue);
    final back = (saved['EVALUATION_ARENA_MODELS'] as List).single as Map;
    expect(back['id'], 'nexus-arena');
    expect(back['meta']['model_ids'], ['tiny:latest']);
    expect(back['meta']['filter_mode'], 'include');
  }, skip: skip);
}
