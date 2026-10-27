import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/read_aloud.dart';

void main() {
  test('markdown becomes words to say', () {
    expect(
      speakable(
        '## Today\n\nYou have **2 emails**:\n\n- From [Ana](https://x.com)\n'
        '- From PG&E\n\n```dart\nprint(1);\n```\n\n| Who | What |\n|---|---|\n'
        '| Ana | forms |\n\nSee https://example.com for more.',
      ),
      'Today\nYou have 2 emails:\nFrom Ana\nFrom PG&E\nWho, What\nAna, forms\n'
      'See for more.',
    );
  });

  test('only finished sentences are ready while writing', () {
    const t = 'First sentence. Second one is still goi';
    expect(t.substring(0, readyUpTo(t, 0)), 'First sentence.');
    expect(readyUpTo(t, 15), 15);
    const code = 'Here:\n```\nprint(1);\nprint(2);';
    expect(readyUpTo(code, 0), 'Here:\n'.length);
    const closed = 'Here:\n```\nprint(1);\n```\nDone. And';
    expect(closed.substring(0, readyUpTo(closed, 0)), endsWith('Done.'));
  });
}
