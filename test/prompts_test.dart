import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/workspace/prompts_api.dart';

void main() {
  const text =
      'Summarize this for {{USER_NAME}} on {{CURRENT_DATE}}:\n\n'
      '{{text | textarea:placeholder="Paste text":required}}\n\n'
      'Tone: {{tone | select:options=["casual","formal"]:default="casual"}} '
      'for {{audience}}';

  test('fills the values the app knows', () {
    final out = fillSystemVariables(
      text,
      userName: 'Joel',
      now: DateTime(2026, 10, 27, 9, 5, 3),
    );
    expect(out, startsWith('Summarize this for Joel on 2026-10-27:'));
  });

  test('reads the placeholders the person fills, as the web does', () {
    final vars = inputVariables(text);
    expect(vars.map((v) => v.name), ['text', 'tone', 'audience']);
    expect(vars[0].type, 'textarea');
    expect(vars[0].placeholder, 'Paste text');
    expect(vars[0].required, isTrue);
    expect(vars[1].type, 'select');
    expect(vars[1].options, ['casual', 'formal']);
    expect(vars[1].initial, 'casual');
    expect(vars[2].type, 'text');
    expect(inputVariables('{{USER_NAME}} {{CLIPBOARD}}'), isEmpty);
  });

  test('puts the answers in place', () {
    expect(
      fillInputVariables(text, {
        'text': 'hello',
        'tone': 'formal',
        'audience': 'my team',
      }),
      endsWith('hello\n\nTone: formal for my team'),
    );
  });
}
