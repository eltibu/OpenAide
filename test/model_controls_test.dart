import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/models/model_info.dart';
import 'package:nexus_assistant/features/chat/model_controls.dart';
import 'package:nexus_assistant/features/workspace/models_api.dart';

const _saved = {
  'thinking': {
    'label': 'Thinking',
    'display': 'slider',
    'default': 'medium',
    'options': {
      'low': {
        'label': 'Low',
        'params': {'reasoning_effort': 'low'},
      },
      'medium': {
        'label': 'Medium',
        'params': {'reasoning_effort': 'medium'},
      },
    },
  },
};

void main() {
  test('controls read and write back as the web keeps them', () {
    final c = readModelControls(_saved);
    expect(c.single.label, 'Thinking');
    expect(c.single.slider, isTrue);
    expect(c.single.defaultOption, 'medium');
    expect(c.single.options.map((o) => o.key), ['low', 'medium']);
    expect(writeModelControls(c), {
      'thinking': {
        'label': 'Thinking',
        'display': 'slider',
        'default': 'medium',
        'options': {
          'low': {
            'label': 'Low',
            'params': {'reasoning_effort': 'low'},
          },
          'medium': {
            'label': 'Medium',
            'params': {'reasoning_effort': 'medium'},
          },
        },
      },
    });
  });

  test('keys and values as the web makes them', () {
    expect(controlKey('Thinking Level', []), 'thinking_level');
    expect(controlKey('Thinking', ['thinking']), 'thinking_2');
    expect(controlKey('3D', []), 'option_3d');
    expect(paramValue('0.5'), 0.5);
    expect(paramValue('true'), true);
    expect(paramValue('high'), 'high');
    expect(paramText('high'), 'high');
    expect(paramText(2), '2');
  });

  test('your picks are read from settings', () {
    expect(
      chosenControls({
        'params': {
          'model_controls': {
            'm': {'thinking': 'low'},
          },
        },
      }),
      {
        'm': {'thinking': 'low'},
      },
    );
    expect(chosenControls(null), isEmpty);
    expect(
      controlsOf(
        ModelInfo.fromJson({
          'id': 'm',
          'info': {
            'params': {'model_controls': _saved},
          },
        }),
      ),
      hasLength(1),
    );
  });

  final url = Platform.environment['OWUI_URL'];
  test('a model keeps its controls and the chat sees them', () async {
    HttpOverrides.global = null;
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(
      Platform.environment['OWUI_EMAIL']!,
      Platform.environment['OWUI_PASSWORD']!,
    );
    final api = ModelsApi(client);
    final base =
        (((await client.send('GET', '/api/models')) as Map)['data'] as List)
            .first['id'];
    await api.save({
      'id': 'nexus-controls-model',
      'name': 'Nexus controls',
      'base_model_id': base,
      'meta': {},
      'params': {'model_controls': _saved},
    }, create: true);
    addTearDown(() => api.delete('nexus-controls-model'));
    final listed =
        ((await client.send('GET', '/api/models')) as Map)['data'] as List;
    final m = ModelInfo.fromJson(
      (listed.firstWhere((m) => m['id'] == 'nexus-controls-model') as Map)
          .cast<String, dynamic>(),
    );
    expect(controlsOf(m).single.options, hasLength(2));
  }, skip: url == null ? 'Set OWUI_URL' : null);
}
