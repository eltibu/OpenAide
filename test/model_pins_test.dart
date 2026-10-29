import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/model_info.dart';
import 'package:nexus_assistant/features/chat/model_pins.dart';

ModelInfo _m(Map<String, dynamic> raw) =>
    ModelInfo(id: '${raw['id']}', name: '${raw['id']}', raw: raw);

void main() {
  test('your pins win over the server defaults, even when empty', () {
    final config = {'default_pinned_models': 'a, b,'};
    expect(pinnedModelIds(null, config), ['a', 'b']);
    expect(pinnedModelIds({'pinnedModels': <String>[]}, config), isEmpty);
    expect(
      pinnedModelIds({
        'pinnedModels': ['c'],
      }, config),
      ['c'],
    );
  });

  test('tags, connection kind and link', () {
    final models = [
      _m({
        'id': 'x',
        'owned_by': 'ollama',
        'tags': [
          {'name': 'fast'},
        ],
      }),
      _m({
        'id': 'y',
        'owned_by': 'openai',
        'tags': [
          {'name': 'code'},
          {'name': 'fast'},
        ],
      }),
      _m({'id': 'z', 'direct': true}),
    ];
    expect(modelTags(models), ['code', 'fast']);
    expect(models.map(modelConnection), ['local', 'external', 'direct']);
    expect(
      modelLink('https://chat.example', 'my model'),
      'https://chat.example/?models=my+model',
    );
  });

  test('who can edit from the picker', () {
    final custom = _m({
      'id': 'c',
      'info': {'base_model_id': 'b', 'user_id': 'u1'},
    });
    final base = _m({'id': 'b'});
    expect(canEditModel(custom, {'id': 'u1', 'role': 'user'}), isTrue);
    expect(canEditModel(custom, {'id': 'u2', 'role': 'admin'}), isFalse);
    expect(canEditModel(base, {'role': 'admin'}), isTrue);
    expect(canEditModel(base, {'role': 'user'}), isFalse);
  });
}
