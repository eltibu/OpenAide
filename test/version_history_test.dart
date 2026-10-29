import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/workspace/version_history.dart';

class _FakeClient extends OpenWebUiClient {
  _FakeClient() : super(baseUrl: 'http://x');
  String current = 'v2';
  final posts = <(String, Object?)>[];

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (method == 'POST') {
      posts.add((path, body));
      current = '${(body as Map)['version_id']}';
      return {};
    }
    if (path.endsWith('/history')) {
      return [
        {'id': 'v2', 'created_at': 2000, 'commit_message': 'Newer'},
        {'id': 'v1', 'created_at': 1000, 'commit_message': 'Older'},
      ];
    }
    return {'version_id': current};
  }
}

void main() {
  test('where each kind keeps its history', () {
    final (path, query) = HistoryPaths('model', 'm 1').list(1);
    expect(path, '/api/v1/models/model/history');
    expect(query, {'id': 'm 1', 'page': '1'});
    expect(HistoryPaths('prompt', 'p').list(1).$2, {'page': '0'});
    expect(
      HistoryPaths('function', 'f').production().$1,
      '/api/v1/functions/id/f/update/version',
    );
    expect(snapshotText({'content': 'code'}), 'code');
  });

  testWidgets('an older version is set as production', (tester) async {
    final client = _FakeClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const VersionHistoryScreen(kind: 'skill', id: 's', name: 'S'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Production'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set as Production'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Set as Production'));
    await tester.pumpAndSettle();
    final (posted, body) = client.posts.single;
    expect(posted, '/api/v1/skills/id/s/update/version');
    expect(body, {'version_id': 'v1', 'expected_version_id': 'v2'});
  });
}
