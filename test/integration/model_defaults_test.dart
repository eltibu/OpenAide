// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/admin/model_defaults.dart';
import 'package:nexus_assistant/features/workspace/models_api.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];

  test('no saved defaults reads as the web starts', () {
    expect(savedCapabilities({}), defaultCapabilities);
    final out = withDefaults(
      {
        'DEFAULT_MODELS': 'a',
        'DEFAULT_MODEL_METADATA': {
          'builtinTools': {'x': true},
        },
      },
      capabilities: {'vision': false},
      params: {'temperature': 0.3, 'seed': null},
    );
    expect(out['DEFAULT_MODELS'], 'a');
    expect(out['DEFAULT_MODEL_METADATA'], {
      'builtinTools': {'x': true},
      'capabilities': {'vision': false},
    });
    expect(out['DEFAULT_MODEL_PARAMS'], {'temperature': 0.3});
  });

  test('defaults and suggestions save on the server', () async {
    HttpOverrides.global = null;
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(
      Platform.environment['OWUI_EMAIL']!,
      Platform.environment['OWUI_PASSWORD']!,
    );
    final api = ModelsApi(client);
    final before = await api.config();
    final server = await client.config();
    addTearDown(() async {
      await api.saveConfig(before);
      await client.send(
        'POST',
        '/api/v1/configs/suggestions',
        body: {
          'suggestions': server['default_prompt_suggestions'],
          'i18n': server['default_prompt_suggestions_i18n'] ?? {},
        },
      );
    });

    await api.saveConfig(
      withDefaults(
        before,
        capabilities: {...defaultCapabilities, 'vision': false},
        params: {'temperature': 0.25},
      ),
    );
    final after = await api.config();
    expect(savedCapabilities(after)['vision'], isFalse);
    expect(after['DEFAULT_MODEL_PARAMS'], {'temperature': 0.25});
    expect(after['DEFAULT_MODELS'], before['DEFAULT_MODELS']);

    await client.send(
      'POST',
      '/api/v1/configs/suggestions',
      body: {
        'suggestions': [
          {
            'title': ['Say hi', 'to everyone'],
            'content': 'Hi!',
          },
        ],
        'i18n': {},
      },
    );
    final shown = (await client.config())['default_prompt_suggestions'] as List;
    expect(shown.single['content'], 'Hi!');
  }, skip: url == null ? 'Set OWUI_URL' : null);
}
