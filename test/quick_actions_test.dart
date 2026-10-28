import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/quick_actions.dart';

void main() {
  test('defaults until you set your own', () {
    expect(quickActions(null).map((a) => a['label']), ['Ask', 'Explain']);
    expect(quickActions({'floatingActionButtons': []}).length, 2);
    expect(
      quickActions({
        'floatingActionButtons': [
          {'id': 't', 'label': 'Translate', 'prompt': 'Translate: {{CONTENT}}'},
        ],
      }).single['label'],
      'Translate',
    );
  });

  test('prompts quote the selection as the web does', () {
    final ask = quickActions(null).first;
    final explain = quickActions(null).last;
    expect(quickActionPrompt(ask, 'one\ntwo'), '> one\n> two\n\n\n');
    expect(quickActionPrompt(explain, 'x'), '> x\n\n\nExplain');
    expect(
      quickActionPrompt({
        'prompt': 'Fix {{CONTENT}} with {{TOOL:web}}{{lang|tool:id="t1"}}',
      }, 'this'),
      'Fix this with lang',
    );
  });
}
