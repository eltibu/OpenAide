import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/chat_drawer.dart';
import 'package:nexus_assistant/features/chat/markdown_extras.dart';

void main() {
  test('active users and running models, as the account menu shows', () {
    expect(
      activeUsersText({'user_count': 1, 'model_ids': []}),
      '1 active user',
    );
    expect(
      activeUsersText({
        'user_count': 3,
        'model_ids': ['nexus', 'llama'],
      }),
      '3 active users · Running: nexus, llama',
    );
  });

  test('saving an edited code block changes that block in the reply', () {
    const reply = 'Try:\n\n```python\nprint(1)\n```\n\nDone.';
    expect(
      replaceCode(reply, 'print(1)\n', 'print(2)\n'),
      'Try:\n\n```python\nprint(2)\n```\n\nDone.',
    );
    expect(replaceCode(reply, 'nope', 'x'), isNull);
  });
}
