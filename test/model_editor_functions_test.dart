import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/model_info.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/admin_api.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/settings/audio_settings.dart';
import 'package:nexus_assistant/features/terminal/terminal_screen.dart';
import 'package:nexus_assistant/features/workspace/knowledge_screen.dart';
import 'package:nexus_assistant/features/workspace/models_screen.dart';

void main() {
  testWidgets('filters and actions to pick, global ones always on', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          modelFunctionsProvider.overrideWith(
            (ref) async => [
              ServerFunction({
                'id': 'clean',
                'name': 'Clean up',
                'type': 'filter',
                'meta': {'toggle': true},
              }),
              ServerFunction({
                'id': 'safety',
                'name': 'Safety',
                'type': 'filter',
                'is_global': true,
              }),
              ServerFunction({
                'id': 'translate',
                'name': 'Translate',
                'type': 'action',
              }),
            ],
          ),
          modelsProvider.overrideWith((ref) async => <ModelInfo>[]),
          toolsProvider.overrideWith((ref) async => []),
          skillsProvider.overrideWith((ref) async => []),
          knowledgeListProvider.overrideWith((ref) async => []),
          ttsVoicesProvider.overrideWith((ref) async => []),
          terminalServersProvider.overrideWith((ref) async => []),
        ],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const ModelEditor(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Translate'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Safety · Global'), findsOneWidget);
    expect(find.textContaining('start enabled'), findsNothing);
    tester
        .widget<FilterChip>(
          find.ancestor(
            of: find.text('Clean up'),
            matching: find.byType(FilterChip),
          ),
        )
        .onSelected!(true);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('start enabled'),
      -100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Clean up: start enabled in new chats'), findsOneWidget);
  });
}
