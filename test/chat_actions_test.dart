import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/chat/chat_drawer.dart';

void main() {
  Future<void> open(WidgetTester tester, {required bool inList}) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showChatActions(
                context,
                ref,
                ChatSummary(
                  id: 'c1',
                  title: 'Trip plan',
                  updatedAt: DateTime(2026),
                ),
                pinned: true,
                inList: inList,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the top bar offers the chat actions, without picking', (
    tester,
  ) async {
    await open(tester, inList: false);
    expect(find.text('Trip plan'), findsOneWidget);
    for (final label in ['Rename', 'Unstar', 'Share', 'Export', 'Delete']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Select chats'), findsNothing);
  });

  testWidgets('the chat list also offers Select chats', (tester) async {
    await open(tester, inList: true);
    expect(find.text('Select chats'), findsOneWidget);
  });
}
