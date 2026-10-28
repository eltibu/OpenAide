import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/pipelines_screen.dart';

class _FakeClient extends OpenWebUiClient {
  _FakeClient() : super(baseUrl: 'http://x');
  final calls = <String>[];
  var pipelines = <Map<String, dynamic>>[
    {'id': 'rate', 'name': 'Rate limit', 'type': 'filter'},
  ];

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    calls.add('$method $path ${body ?? query ?? ''}');
    if (path.endsWith('/list')) {
      return {
        'data': [
          {'url': 'http://pipes:9099', 'idx': 1},
        ],
      };
    }
    if (method == 'DELETE') pipelines = [];
    return {'data': pipelines};
  }
}

void main() {
  testWidgets('lists a server\'s pipelines and deletes one', (tester) async {
    final client = _FakeClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const PipelinesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('http://pipes:9099'), findsOneWidget);
    expect(find.text('Rate limit'), findsOneWidget);
    expect(client.calls, contains('GET /api/v1/pipelines/ {urlIdx: 1}'));
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(
      client.calls,
      contains('DELETE /api/v1/pipelines/delete {id: rate, urlIdx: 1}'),
    );
    expect(find.text('No pipelines on this server yet.'), findsOneWidget);
  });
}
