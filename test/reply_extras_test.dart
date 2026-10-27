import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as m;
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/chat/markdown_extras.dart';
import 'package:nexus_assistant/features/chat/reply_actions.dart';

List<m.Element> _math(String text) {
  final doc = m.Document(
    extensionSet: m.ExtensionSet.gitHubFlavored,
    inlineSyntaxes: [LatexSyntax()],
    encodeHtml: false,
  );
  final out = <m.Element>[];
  void walk(List<m.Node>? nodes) {
    for (final n in nodes ?? const <m.Node>[]) {
      if (n is m.Element) {
        if (n.tag == LatexSyntax.tag) out.add(n);
        walk(n.children);
      }
    }
  }

  walk(doc.parseLines(text.split('\n')));
  return out;
}

void main() {
  test('math is found in all four KaTeX forms', () {
    final found = _math(
      r'Inline $a^2 + b^2$ and \(x_1\), block $$\int_0^1 f$$ and \[E=mc^2\]',
    );
    expect(found.map((e) => e.attributes['tex']), [
      'a^2 + b^2',
      'x_1',
      r'\int_0^1 f',
      'E=mc^2',
    ]);
    expect(found.map((e) => e.attributes['display']), [
      'false',
      'false',
      'true',
      'true',
    ]);
  });

  test('prices are not math', () {
    expect(_math(r'It costs $5 and $10 today.'), isEmpty);
    expect(_math(r'Between $ 5 and $ 6'), isEmpty);
  });

  test('markdown tables become CSV', () {
    const text = '''Here:

| Name | Price, USD | Note |
|------|-----------:|------|
| Tea  | 3 | "hot" |
| Cake | 5 | a \\| b |

Done.''';
    expect(markdownTablesAsCsv(text), [
      'Name,"Price, USD",Note\nTea,3,"""hot"""\nCake,5,a | b',
    ]);
    expect(markdownTablesAsCsv('no tables | here'), isEmpty);
  });

  test('sources keep the passages the model read', () {
    final reply = ChatMessage.fromJson({
      'id': 'r',
      'role': 'assistant',
      'content': 'x',
      'sources': [
        {
          'source': {'name': 'notes.pdf'},
          'document': ['first part', 'second part'],
          'metadata': [
            {'source': 'notes.pdf', 'name': 'notes.pdf'},
            {'source': 'notes.pdf', 'name': 'notes.pdf'},
          ],
          'distances': [0.82, 0.4],
        },
      ],
    });
    final s = reply.sources.single;
    expect(s.name, 'notes.pdf');
    expect(s.passages.map((p) => p.text), ['first part', 'second part']);
    expect(s.passages.first.relevance, closeTo(0.82, 1e-9));
  });

  test('prompt suggestions: the model first, else the server', () {
    final config = {
      'default_prompt_suggestions': [
        {
          'title': ['Help me study', 'vocabulary for an exam'],
          'content': 'Help me study vocabulary',
        },
      ],
    };
    expect(
      promptSuggestions(null, config).single.subtitle,
      'vocabulary for an exam',
    );
    final own = promptSuggestions({
      'suggestion_prompts': [
        {'content': 'Plan my day'},
      ],
    }, config);
    expect(own.single.title, 'Plan my day');
  });

  test('ratings read from the annotation', () {
    final r = ChatMessage(
      id: 'r',
      role: 'assistant',
      content: 'x',
      extra: {
        'annotation': {'rating': -1},
      },
    );
    expect(ratingOf(r), -1);
  });
}
