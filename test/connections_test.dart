import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/admin/connections_screen.dart';

void main() {
  test('reads and writes OpenAI connections with keys beside them', () {
    final list = readConnections(openAiConnections, {
      'ENABLE_OPENAI_API': true,
      'OPENAI_API_BASE_URLS': ['http://a/v1', 'http://b/v1'],
      'OPENAI_API_KEYS': ['ka', 'kb'],
      'OPENAI_API_CONFIGS': {
        '1': {'enable': false, 'prefix_id': 'b'},
      },
    });
    expect(list.map((c) => c.key), ['ka', 'kb']);
    expect(list[1].enabled, isFalse);
    list.removeAt(0);
    expect(writeConnections(openAiConnections, true, list), {
      'ENABLE_OPENAI_API': true,
      'OPENAI_API_BASE_URLS': ['http://b/v1'],
      'OPENAI_API_KEYS': ['kb'],
      'OPENAI_API_CONFIGS': {
        '0': {'enable': false, 'prefix_id': 'b'},
      },
    });
  });

  test('Ollama keeps each key in its own settings', () {
    final list = readConnections(ollamaConnections, {
      'OLLAMA_BASE_URLS': ['http://o'],
      'OLLAMA_API_CONFIGS': {
        '0': {'key': 'k'},
      },
    });
    expect(list.single.key, 'k');
    expect(writeConnections(ollamaConnections, false, list), {
      'ENABLE_OLLAMA_API': false,
      'OLLAMA_BASE_URLS': ['http://o'],
      'OLLAMA_API_CONFIGS': {
        '0': {'key': 'k'},
      },
    });
  });
}
