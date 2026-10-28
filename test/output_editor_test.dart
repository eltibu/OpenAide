import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/chat/output_editor.dart';

final _output = [
  {
    'type': 'reasoning',
    'summary': [
      {'type': 'text', 'text': 'Look up the weather'},
    ],
  },
  {
    'type': 'function_call',
    'call_id': 'c1',
    'name': 'get_weather',
    'arguments': '{"city":"Paris"}',
  },
  {
    'type': 'function_call_output',
    'call_id': 'c1',
    'output': [
      {'type': 'input_text', 'text': 'Sunny'},
    ],
  },
  {
    'type': 'message',
    'content': [
      {'type': 'output_text', 'text': 'It is sunny.'},
    ],
  },
];

void main() {
  test('rows group a tool call with its result', () {
    final rows = outputRows(_output);
    expect(rows.map((r) => r.label), ['Thought', 'get_weather', 'Text']);
    expect(rows[1].indices, [1, 2]);
    expect(messageText(rows[2].item), 'It is sunny.');
    expect(reasoningText(rows[0].item), 'Look up the weather');
  });

  test('editing and deleting change only their items', () {
    var out = setMessageText(_output, 3, 'Sunny in Paris.');
    expect(messageText(out[3] as Map), 'Sunny in Paris.');
    expect(messageText(_output[3]), 'It is sunny.');
    out = setReasoningText(out, 0, 'Check Paris');
    expect(reasoningText(out[0] as Map), 'Check Paris');
    out = removeItems(out, [1, 2]);
    expect(out.map((i) => (i as Map)['type']), ['reasoning', 'message']);
  });

  testWidgets('Visual and JSON views, then Save', (tester) async {
    OutputEdit? got;
    await tester.pumpWidget(
      MaterialApp(
        theme: nexusTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => got = await editOutput(context, _output),
            child: const Text('Edit'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('get_weather'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'It is sunny.'),
      'Warm.',
    );
    // Drop the tool call.
    await tester.tap(find.byTooltip('Delete').at(1));
    await tester.pumpAndSettle();
    expect(find.text('get_weather'), findsNothing);
    await tester.tap(find.text('Visual'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"Warm."'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '{"x":1}');
    await tester.pump();
    expect(find.text('Must be a JSON array'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '[]');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(got!.output, isEmpty);
    expect(got!.asCopy, isFalse);
  });
}
