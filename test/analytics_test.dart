import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/analytics_screen.dart';

class _FakeClient extends OpenWebUiClient {
  _FakeClient() : super(baseUrl: 'http://x');
  final queries = <Map<String, String>?>[];

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    queries.add(query);
    return switch (path.split('/').last) {
      'summary' => {
        'total_messages': 12000,
        'total_chats': 9,
        'total_models': 1,
        'total_users': 1,
      },
      'models' => {
        'models': [
          {
            'model_id': 'nexus',
            'count': 11,
            'unique_users': 1,
            'unique_chats': 9,
          },
        ],
      },
      'users' => {
        'users': [
          {
            'user_id': 'u',
            'name': 'Joel',
            'email': 'j@x',
            'count': 11,
            'total_tokens': 50,
          },
        ],
      },
      'daily' => {
        'data': [
          {
            'date': '2026-10-26',
            'models': {'nexus': 4},
          },
          {
            'date': '2026-10-27',
            'models': {'nexus': 7},
          },
        ],
      },
      _ => {
        'models': [
          {'model_id': 'nexus', 'total_tokens': 1234},
        ],
      },
    };
  }
}

void main() {
  testWidgets('shows totals, activity, models and people', (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final client = _FakeClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const AnalyticsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('12.0k'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('nexus'), findsOneWidget);
    expect(find.textContaining('1234 tokens'), findsOneWidget);
    expect(find.text('Joel'), findsOneWidget);
    expect(client.queries.first, contains('start_date'));
    client.queries.clear();
    await tester.ensureVisible(find.text('All time'));
    await tester.tap(find.text('All time'));
    await tester.pumpAndSettle();
    expect(client.queries.first, isEmpty);
  });
}
