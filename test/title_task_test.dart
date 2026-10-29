import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/chat_extras.dart';

Map reply(String content) => {
  'choices': [
    {
      'message': {'content': content},
    },
  ],
};

void main() {
  test('reads the title out of the task reply', () {
    expect(titleFromTask(reply('{"title": "🌍 Trip plans"}')), '🌍 Trip plans');
    expect(titleFromTask(reply("Sure! {'title': 'Taxes'}")), 'Taxes');
    expect(titleFromTask(reply('{"title": ""}')), isNull);
    expect(titleFromTask(reply('no json')), isNull);
    expect(titleFromTask(null), isNull);
  });
}
