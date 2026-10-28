import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/chat/copy_text.dart';

void main() {
  test('a formatted copy holds the reply as HTML', () {
    final html = copyHtml('# Plan\n\n- **Ship** it\n- [Docs](https://x.io)');
    expect(html, contains('Plan</h1>'));
    expect(html, contains('<strong>Ship</strong>'));
    expect(html, contains('<a href="https://x.io">Docs</a>'));
  });

  test('a source from one of your files keeps its file id', () {
    final m = ChatMessage.fromJson({
      'id': 'a',
      'role': 'assistant',
      'content': 'x',
      'sources': [
        {
          'source': {'type': 'file', 'id': 'f1', 'name': 'plan.pdf'},
          'document': ['The plan'],
          'metadata': [
            {'name': 'plan.pdf', 'file_id': 'f1', 'source': 'plan.pdf'},
          ],
        },
        {
          'source': {'name': 'Web', 'url': 'https://x.io'},
          'document': ['Page'],
          'metadata': [
            {'source': 'https://x.io', 'name': 'X'},
          ],
        },
      ],
    });
    expect(m.sources.first.fileId, 'f1');
    expect(m.sources.first.url, isNull);
    expect(m.sources.last.fileId, isNull);
    expect(m.sources.last.url, 'https://x.io');
  });

}
