import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/studio/studio_doc.dart';
import 'package:nexus_assistant/features/studio/studio_export.dart';

const _doc = '''Intro line.

## Objetivos

- Hablar del pasado
- Usar el pretérito **bien**
  1. uno
  2. dos

## Actividades

Paragraph one with *style* and `code`.

```
## not a heading
```

### Detail

> a quote

---

| a | b |
|---|---|
| 1 | 2 |
''';

void main() {
  test('sections split at headings and join back', () {
    final s = splitSections(_doc);
    expect(s.map((x) => x.heading), ['', 'Objetivos', 'Actividades', 'Detail']);
    expect(s[0].level, 0);
    expect(s[2].body, contains('## not a heading'));
    expect(s[3].level, 3);
    expect(
      splitSections(joinSections(s)).map((x) => x.toMarkdown()),
      s.map((x) => x.toMarkdown()),
    );
  });

  test('AI text loses its fence, and a title is found', () {
    expect(cleanAiText('```markdown\n# T\n\nhi\n```'), '# T\n\nhi');
    expect(titleAndBody('# Mi clase\n\n## Uno\nx'), ('Mi clase', '## Uno\nx'));
    expect(titleAndBody('no title').$1, '');
  });

  test('blocks read lists, quotes, code and tables', () {
    final b = markdownBlocks(_doc);
    final kinds = b.map((x) => x.kind).toList();
    expect(
      kinds,
      containsAll(['h2', 'bullet', 'number', 'code', 'quote', 'rule', 'h3']),
    );
    final nested = b.firstWhere((x) => x.kind == 'number');
    expect(nested.level, 1);
    expect(nested.number, 1);
    final bold = b.firstWhere((x) => x.text.startsWith('Usar'));
    expect(bold.runs.any((r) => r.bold && r.text == 'bien'), isTrue);
    final table = b.firstWhere((x) => x.kind == 'table');
    expect(table.rows.length, greaterThan(1));
  });

  test('Word file is a real docx', () {
    final bytes = toDocx('Mi clase', _doc);
    final zip = ZipDecoder().decodeBytes(bytes);
    final doc = utf8.decode(
      zip.findFile('word/document.xml')!.content as List<int>,
    );
    expect(doc, contains('Heading2'));
    expect(doc, contains('pretérito'));
    expect(zip.findFile('word/styles.xml'), isNotNull);
    expect(zip.findFile('[Content_Types].xml'), isNotNull);
  });

  test('PDF is made, accents and odd symbols included', () async {
    final theme = await pdfTheme(
      (path) async => ByteData.sublistView(File(path).readAsBytesSync()),
    );
    final bytes = await toPdf(
      'Mañana',
      '$_doc\n“quotes” — ñ • á',
      theme: theme,
    );
    expect(utf8.decode(bytes.sublist(0, 5), allowMalformed: true), '%PDF-');
  });
}
