import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/attach_more.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/notes/notes_api.dart';
import 'package:nexus_assistant/features/workspace/knowledge_api.dart';
import 'package:nexus_assistant/features/workspace/knowledge_screen.dart';

void main() {
  Future<ProviderContainer> show(WidgetTester tester, String query) async {
    final container = ProviderContainer(
      overrides: [
        knowledgeListProvider.overrideWith(
          (ref) async => [
            Knowledge(
              id: 'k1',
              name: 'School policies',
              description: 'Handbook',
              updated: DateTime(2026),
            ),
            Knowledge(
              id: 'k2',
              name: 'Recipes',
              description: '',
              updated: DateTime(2026),
            ),
          ],
        ),
        hashNotesProvider.overrideWith((ref) async => <Note>[]),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: HashMentions(query: query, onDone: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('# lists matching knowledge and attaches it', (tester) async {
    final c = await show(tester, 'school');
    expect(find.text('School policies'), findsOneWidget);
    expect(find.text('Recipes'), findsNothing);
    await tester.tap(find.text('School policies'));
    await tester.pump();
    final a = c.read(chatControllerProvider).attachments.single;
    expect(a.uploaded?.type, 'collection');
    expect(a.uploaded?.id, 'k1');
  });

  testWidgets('# with a web address offers the page', (tester) async {
    await show(tester, 'example.com/page');
    expect(find.text('Attach example.com/page'), findsOneWidget);
  });
}
