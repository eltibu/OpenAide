import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/compare_text.dart';

void main() {
  test('by line, by word, ignoring spacing and emphasis', () {
    expect(
      textDiff('a\nb\nc', 'a\nB\nc').map((l) => '${l.kind}${l.text}'),
      [' a', '-b', '+B', ' c'],
    );
    final words = textDiff('the quick fox', 'the slow fox', approximate: true);
    expect(words.where((l) => l.kind != ' ').map((l) => l.text.trim()), [
      'quick',
      'slow',
    ]);
    expect(
      textDiff('a  b', 'a b', ignoreSpace: true).every((l) => l.kind == ' '),
      isTrue,
    );
    expect(
      textDiff('**bold** text', 'bold text', ignoreEmphasis: true)
          .every((l) => l.kind == ' '),
      isTrue,
    );
  });

  testWidgets('compare and use the revision', (tester) async {
    String? used;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              used = await Navigator.push<String>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      const CompareTextScreen(original: 'one\ntwo'),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'one\nthree');
    await tester.tap(find.text('Compare'));
    await tester.pumpAndSettle();
    expect(find.text('1 added · 1 removed'), findsOneWidget);
    expect(find.text('- two'), findsOneWidget);
    expect(find.text('+ three'), findsOneWidget);
    await tester.tap(find.byTooltip('Options'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckedPopupMenuItem<String>).last);
    await tester.pumpAndSettle();
    expect(find.text('  one'), findsNothing);
    expect(find.text('- two'), findsOneWidget);
    await tester.tap(find.text('Use in prompt'));
    await tester.pumpAndSettle();
    expect(used, 'one\nthree');
  });
}
