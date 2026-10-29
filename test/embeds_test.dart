import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/chat/embeds_view.dart';

const _player =
    '<iframe width="560" height="315" '
    'src="https://www.youtube.com/embed/dQw4w9WgXcQ"></iframe>';

void main() {
  test('a reply shows the players its tools sent, once each', () {
    final m = ChatMessage.fromJson({
      'id': 'a',
      'role': 'assistant',
      'content': 'Here it is',
      'embeds': [_player],
      'output': [
        {
          'type': 'function_call_output',
          'call_id': 'c1',
          'output': [
            {'type': 'input_text', 'text': 'ok'},
          ],
          'embeds': [_player, '/api/v1/files/x/content'],
        },
      ],
    });
    expect(m.embeds, [_player, '/api/v1/files/x/content']);
    expect(ChatMessage.fromJson({'id': 'b', 'role': 'assistant'}).embeds, []);
  });

  test('the page around an embed keeps it and reports its height', () {
    final page = embedPage(_player);
    expect(page, contains(_player));
    expect(page, contains('NexusSize.postMessage'));
    expect(page, contains('width=device-width'));
  });
}
