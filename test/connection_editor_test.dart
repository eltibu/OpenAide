import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/connections_screen.dart';

void main() {
  testWidgets('provider, Responses API, cookies and headers are saved', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 5000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    Object? saved;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => saved = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ConnectionEditor(
                    kind: openAiConnections,
                    connection: Connection(
                      url: 'https://x.openai.azure.com/',
                      key: 'k',
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // An Azure address asks for the API version.
    expect(find.text('API Version'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'API Version'),
      '2024-10-21',
    );
    await tester.tap(find.text('Chat Completions'));
    await tester.tap(find.text('Forward cookies'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Headers'),
      '{"X-A": "1"}',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final c = saved as Connection;
    expect(c.url, 'https://x.openai.azure.com');
    expect(c.config['api_type'], 'responses');
    expect(c.config['forward_cookies'], isTrue);
    expect(c.config['azure'], isTrue);
    expect(c.config['api_version'], '2024-10-21');
    expect(c.config['headers'], {'X-A': '1'});
  });
}
