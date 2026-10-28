import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/formatting_toolbar.dart';

TextEditingValue _v(String text, int start, [int? end]) => TextEditingValue(
  text: text,
  selection: TextSelection(baseOffset: start, extentOffset: end ?? start),
);

void main() {
  test('bold wraps and unwraps the selection', () {
    final on = wrapSelection(_v('make this bold', 5, 9), '**');
    expect(on.text, 'make **this** bold');
    expect(on.selection, const TextSelection(baseOffset: 7, extentOffset: 11));
    expect(wrapSelection(on, '**').text, 'make this bold');
    expect(wrapSelection(_v('x', 1), '<u>', '</u>').text, 'x<u></u>');
  });

  test('lines become headings and lists, and back', () {
    final h = editLines(_v('one\ntwo', 5), (l, _) => headingLine(l, 2));
    expect(h.text, 'one\n## two');
    expect(
      editLines(_v(h.text, 5), (l, _) => headingLine(l, 2)).text,
      'one\ntwo',
    );
    final list = editLines(_v('a\nb\nc', 0, 5), (l, i) => listLine(l, i, '1.'));
    expect(list.text, '1. a\n2. b\n3. c');
    final bullets = editLines(
      _v(list.text, 0, list.text.length),
      (l, i) => listLine(l, i, '-'),
    );
    expect(bullets.text, '- a\n- b\n- c');
    expect(editLines(_v('- a', 0), (l, i) => listLine(l, i, '-')).text, 'a');
    expect(
      editLines(_v('task', 0), (l, i) => listLine(l, i, '- [ ]')).text,
      '- [ ] task',
    );
  });

  testWidgets('toolbar buttons edit the box', (tester) async {
    final c = TextEditingController(text: 'hello');
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FormattingToolbar(controller: c)),
      ),
    );
    await tester.tap(find.byTooltip('Italic'));
    expect(c.text, '*hello*');
    await tester.tap(find.byTooltip('H1'));
    expect(c.text, '# *hello*');
  });
}
