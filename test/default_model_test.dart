import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/model_info.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';

void main() {
  final models = [
    ModelInfo(id: 'llama', name: 'Llama', raw: const {}),
    ModelInfo(id: 'nexus', name: 'Nexus', raw: const {}),
    ModelInfo(id: 'gpt', name: 'GPT', raw: const {}),
  ];

  test('your default wins, then the server default, then the first', () {
    expect(
      pickDefaultModel(
        models,
        {
          'ui': {
            'models': ['gone', 'nexus'],
          },
        },
        {'default_models': 'gpt'},
      ),
      'nexus',
    );
    expect(
      pickDefaultModel(models, const {}, {'default_models': ' gpt,llama'}),
      'gpt',
    );
    expect(pickDefaultModel(models, const {}, const {}), 'llama');
    expect(pickDefaultModel(const [], const {}, const {}), isNull);
  });
}
