import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/markdown_extras.dart';

void main() {
  testWidgets('a folded code block opens on tap', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: const MaterialApp(
          home: Scaffold(
            body: CodeFrame(
              code: 'a = 1\nb = 2\n',
              language: 'python',
              collapsed: true,
              child: Text('THE CODE'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('python · 2 lines'), findsOneWidget);
    expect(find.text('THE CODE'), findsNothing);
    await tester.tap(find.text('python · 2 lines'));
    await tester.pump();
    expect(find.text('THE CODE'), findsOneWidget);
  });

  testWidgets('Python blocks offer Run and Expand', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: CodeFrame(
              code: 'print(1)',
              language: 'python',
              child: SizedBox(height: 80, child: Text('THE CODE')),
            ),
          ),
        ),
      ),
    );
    expect(find.byTooltip('Run'), findsOneWidget);
    await tester.tap(find.byTooltip('Expand'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'python'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });
}
