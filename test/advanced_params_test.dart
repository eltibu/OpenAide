import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/chat/advanced_params.dart';

void main() {
  test('stop words become a list, empty is default', () {
    expect(stopWords(' END, \\n\\n ,'), ['END', '\\n\\n']);
    expect(stopWords('  '), isNull);
  });

  testWidgets('sets every kind of parameter as the web stores it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 8000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final params = <String, dynamic>{'num_ctx': 8192};
    await tester.pumpWidget(
      MaterialApp(
        theme: nexusTheme(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ListView(
              children: [
                AdvancedParamsEditor(
                  params: params,
                  onChanged: (k, v) => setState(
                    () => v == null ? params.remove(k) : params[k] = v,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Ollama settings open when one is already set.
    expect(find.textContaining('8192'), findsOneWidget);

    await tester.tap(find.text('Temperature'));
    await tester.pump();
    expect(params['temperature'], 0.8);

    // Toggle: on, off, default.
    final stream = find
        .ancestor(
          of: find.text('Stream response'),
          matching: find.byType(Column),
        )
        .first;
    await tester.tap(find.descendant(of: stream, matching: find.text('Off')));
    await tester.pump();
    expect(params['stream_response'], isFalse);

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'END, STOP');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(params['stop'], ['END', 'STOP']);

    await tester.tap(find.text('Max tokens'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '512');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(params['max_tokens'], 512);

    await tester.tap(find.text('Add custom parameter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'response_format');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      '{"type":"json_object"}',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(params['custom_params'], {
      'response_format': '{"type":"json_object"}',
    });

    await tester.tap(find.text('Mirostat 2.0'));
    await tester.pump();
    expect(params['mirostat'], 2);
  });
}
