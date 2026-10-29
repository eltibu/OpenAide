import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/studio/office.dart';
import 'package:nexus_assistant/features/studio/sheet.dart';
import 'package:nexus_assistant/features/studio/slides.dart';
import 'package:nexus_assistant/features/studio/studio_export.dart';

Sheet _budget() => Sheet(
  name: 'Budget',
  rows: [
    ['Item', 'Cost', 'Qty', 'Total'],
    ['Paper', r'$3.50', '10', '=B2*C2'],
    ['Pens | blue', '1,200', '2', '=B3*C3'],
    ['Zip', '007', '45%', '=ROUND(B2/3, 2)'],
    ['Sum', '', '', '=SUM(D2:D3)'],
  ],
);

/// Where files go for a look with other tools, when asked.
void _keep(String name, List<int> bytes) {
  final dir = Platform.environment['OFFICE_OUT'];
  if (dir != null) File('$dir/$name').writeAsBytesSync(bytes);
}

void main() {
  group('sheet', () {
    test('formulas work out', () {
      final c = SheetCalc(_budget());
      expect(c.display(1, 3), '35');
      expect(c.display(2, 3), '2400');
      expect(c.display(4, 3), '2435');
      expect(c.display(3, 3), '1.17');
      expect(c.value(3, 2), 0.45);
      expect(c.display(3, 1), '007');
      expect(c.value(3, 1), 7);
    });

    test('errors, text and cycles', () {
      final s = Sheet(
        name: 'x',
        rows: [
          ['=A2', '=1/0', '="a"&B3', '=NOPE(1)'],
          ['=A1', '=A1:A2', 'hi', '=IF(C2="hi", 1, 2)'],
          ['=AVERAGE(5, 7)', '=MAX(A3, 10) - MIN(1;2)', '=2^3', '=-3+ABS(-1)'],
        ],
      );
      final c = SheetCalc(s);
      expect(c.display(0, 0), '#CYCLE!');
      expect(c.display(0, 1), '#DIV/0!');
      expect(c.display(0, 2), 'a9');
      expect(c.display(0, 3), '#NAME?');
      expect(c.display(1, 1), '#VALUE!');
      expect(c.display(2, 0), '6');
      expect(c.display(2, 1), '9');
      expect(c.display(2, 2), '8');
      expect(c.display(2, 3), '-2');
    });

    test('columns are named like a spreadsheet', () {
      expect(columnName(0), 'A');
      expect(columnName(25), 'Z');
      expect(columnName(26), 'AA');
      expect(columnIndex('AA'), 26);
      expect(columnIndex('b'), 1);
    });

    test('Markdown round trip keeps cells, bars and line breaks', () {
      final a = _budget()..set(1, 0, 'two\nlines');
      final md = sheetsToMarkdown([a, Sheet(name: 'Second')]);
      expect(studioKind(md), 'sheet');
      final back = sheetsFromMarkdown(md);
      expect(back.map((s) => s.name), ['Budget', 'Second']);
      expect(back.first.rows, a.rows);
    });

    test('tables a model wrote are read as sheets', () {
      final s = sheetsFromMarkdown(
        'Here it is:\n\n### Grades\n\n| Name | Score |\n|:--|--:|\n| Ana | 9 |\n'
        '| Luis | 8 | extra |\n',
      );
      expect(s.single.name, 'Grades');
      expect(s.single.rows.last, ['Luis', '8', 'extra']);
      expect(s.single.rows.first, ['Name', 'Score', '']);
    });

    test('rows and columns are added and removed', () {
      final s = Sheet(
        name: 'x',
        rows: [
          ['a', 'b'],
          ['c', 'd'],
        ],
      );
      s.insertColumn(1);
      expect(s.rows.first, ['a', '', 'b']);
      s.removeColumn(0);
      s.insertRow(0);
      expect(s.rows.length, 3);
      s.set(5, 4, 'z');
      expect(s.rows.length, 6);
      expect(s.columnCount, 5);
      s.set(5, 4, '');
      s.trim();
      expect(s.rows.length, 3);
      expect(s.columnCount, 2);
    });
  });

  test('formulas follow rows and columns that move', () {
    expect(shiftRefs('=SUM(B2:B5)+"B3"', row: 3, rowBy: 1), '=SUM(B2:B6)+"B3"');
    expect(
      shiftRefs(r'=A1*$C$2+LOG10(1)', col: 1, colBy: 1),
      r'=A1*$D$2+LOG10(1)',
    );
    final s = _budget()..insertRow(1);
    expect(s.cell(2, 3), '=B3*C3');
    expect(s.cell(5, 3), '=SUM(D3:D4)');
    s.removeColumn(0);
    expect(s.cell(2, 2), '=A3*B3');
    expect(SheetCalc(s).display(5, 2), '2435');
  });

  group('slides', () {
    const deck =
        '$slidesMarker\n\n## Welcome\n\nA talk about **cats**\n\n'
        '## Why cats\n\n- They purr\n  - Loudly\n- They sleep\n\nNotes: Smile.\nPause here.\n\n'
        '## \n\nJust text';

    test('Markdown round trip', () {
      final s = slidesFromMarkdown(deck);
      expect(studioKind(deck), 'slides');
      expect(s.map((x) => x.title), ['Welcome', 'Why cats', '']);
      expect(s[1].notes, 'Smile.\nPause here.');
      expect(s[1].body, '- They purr\n  - Loudly\n- They sleep');
      final again = slidesFromMarkdown(slidesToMarkdown(s));
      expect(again.map((x) => x.toMarkdown()), s.map((x) => x.toMarkdown()));
    });

    test('points keep their depth', () {
      final p = slidePoints('- One\n  - Two\n1. Three\nplain **bold**');
      expect(p.map((x) => x.level), [0, 1, 0, 0]);
      expect(p.last.bullet, isFalse);
      expect(plainText(p.last.text), 'plain bold');
    });

    test('text with no slide headings is one slide', () {
      final s = slidesFromMarkdown('- a\n- b');
      expect(s.single.body, '- a\n- b');
    });
  });

  group('office files', () {
    test('Excel round trip', () {
      final bytes = toXlsx([_budget(), Sheet(name: 'Notes: [x]')]);
      _keep('budget.xlsx', bytes);
      final back = sheetsFromXlsx(bytes);
      expect(back.map((s) => s.name), ['Budget', 'Notes x']);
      final b = back.first;
      expect(b.cell(0, 0), 'Item');
      expect(b.cell(1, 3), '=B2*C2');
      expect(b.cell(2, 0), 'Pens | blue');
      expect(b.cell(3, 1), '007');
      expect(b.cell(3, 2), '45%');
      expect(b.cell(1, 1), '3.5');
      expect(b.cell(2, 1), '1200');
    });

    test('CSV round trip', () {
      final csv = toCsv(_budget());
      expect(csv.split('\r\n')[1], 'Paper,\$3.50,10,35');
      final back = sheetFromCsv(csv);
      expect(back.cell(2, 0), 'Pens | blue');
      expect(back.cell(2, 1), '1,200');
      expect(sheetFromCsv('a;b\n"x;y";2\n').cell(1, 0), 'x;y');
    });

    test('PowerPoint round trip', () {
      final slides = slidesFromMarkdown(
        '## My talk\n\nBy Joel\n\n## Points\n\n- One **big**\n  - Deeper\n- Two\n\n'
        'Notes: Say hi\n\n## Last\n\n- Bye & thanks <3',
      );
      final bytes = toPptx('My talk', slides);
      _keep('talk.pptx', bytes);
      final back = slidesFromPptx(bytes);
      expect(back.map((s) => s.title), ['My talk', 'Points', 'Last']);
      expect(back[0].body, 'By Joel');
      expect(back[1].body, '- One **big**\n  - Deeper\n- Two');
      expect(back[1].notes, 'Say hi');
      expect(back[2].body, '- Bye & thanks <3');
      _keep('plain.pptx', toPptx('No notes', [Slide(title: 'Only')]));
    });

    test('Word round trip', () {
      const md =
          '## Intro\n\nSome **bold** and *italic* text.\n\n- one\n- two\n'
          '   - deeper\n\n1. first\n2. second\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n'
          '> quoted';
      final bytes = toDocx('My doc', md);
      _keep('doc.docx', bytes);
      final (title, back) = markdownFromDocx(bytes);
      expect(title, 'My doc');
      expect(back, contains('## Intro'));
      expect(back, contains('**bold**'));
      expect(back, contains('*italic*'));
      expect(back, contains('| a | b |\n|---|---|\n| 1 | 2 |'));
      expect(back, contains('quoted'));
    });

    test('slides as PDF', () async {
      final bytes = await slidesToPdf('t', slidesFromMarkdown('## A\n\n- b'));
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });

    test('not an office file', () {
      expect(
        () => sheetsFromXlsx(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<OfficeFileError>()),
      );
    });
  });
}
