import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/settings/usage_screen.dart';

void main() {
  test('short numbers and durations', () {
    expect(shortNumber(null), '0');
    expect(shortNumber(950), '950');
    expect(shortNumber(1234), '1.2K');
    expect(shortNumber(2500000), '2.5M');
    expect(shortNumber(12.5), '12.5');
    expect(shortDuration(30), '30s');
    expect(shortDuration(240), '4m');
    expect(shortDuration(7500), '2h 5m');
  });

  testWidgets('the usage page lays out on a phone', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final week = {'date': '2026-10-20', 'messages': 4, 'tokens': 900};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          usageProvider.overrideWith(
            (ref) async => {
              'totals': {
                'lifetime_tokens': 123456,
                'current_streak': 3,
                'user_messages': 10,
              },
              'insights': {'user_message_share': 50.0},
              'weekly_heatmap': [for (var i = 0; i < 40; i++) week],
              'top_models': [
                {'model_id': 'nexus', 'messages': 10, 'total_tokens': 5000},
              ],
              'top_tools': [
                {'name': 'web_search', 'count': 2},
              ],
            },
          ),
          modelsProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const UsageScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('123K'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('web_search'), 300);
    expect(find.text('web_search'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
