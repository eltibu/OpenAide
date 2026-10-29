import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/workspace/models_screen.dart';

void main() {
  test('suggestions read as the server keeps them', () {
    expect(readSuggestions(null), isNull);
    expect(
      readSuggestions([
        {'title': 'One', 'content': 'a'},
        {
          'title': ['Two', 'more'],
          'content': 'b',
        },
      ]),
      [
        {
          'title': ['One', ''],
          'content': 'a',
        },
        {
          'title': ['Two', 'more'],
          'content': 'b',
        },
      ],
    );
  });

  testWidgets('custom suggestions: add, then back to default', (tester) async {
    List<Map<String, dynamic>>? value;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, set) => SingleChildScrollView(
              child: PromptSuggestionsEditor(
                value: value,
                onChanged: (v) => set(() => value = v),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Default'), findsOneWidget);
    await tester.tap(find.text('Prompt suggestions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use default'));
    await tester.pumpAndSettle();
    expect(value, isEmpty);
    await tester.tap(find.text('Add prompt suggestion'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Plan');
    await tester.enterText(
      find.widgetWithText(TextField, 'Prompt'),
      'Plan my day',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(value, [
      {
        'title': ['Plan', ''],
        'content': 'Plan my day',
      },
    ]);
    expect(find.text('Custom · 1'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove prompt suggestion'));
    await tester.pumpAndSettle();
    expect(value, isEmpty);
  });
}
