import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/workspace/access_editor.dart';

class _FakeClient extends OpenWebUiClient {
  _FakeClient() : super(baseUrl: 'http://x');
  Object? saved;
  String? path;

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (path == '/api/v1/groups/') {
      return [
        {'id': 'g1', 'name': 'Family'},
      ];
    }
    this.path = path;
    saved = body;
    return {};
  }
}

void main() {
  testWidgets('makes a model public, editable by a group', (tester) async {
    final client = _FakeClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const AccessEditor(
            kind: 'model',
            id: 'nexus',
            name: 'Nexus',
            grants: [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Public'));
    await tester.pump();
    await tester.tap(find.text('Add Access'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Can use'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Can edit').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(client.path, '/api/v1/models/model/access/update');
    final body = client.saved as Map;
    expect(body['id'], 'nexus');
    expect((body['access_grants'] as List).toSet(), {
      {'principal_type': 'user', 'principal_id': '*', 'permission': 'read'},
      {'principal_type': 'group', 'principal_id': 'g1', 'permission': 'read'},
      {'principal_type': 'group', 'principal_id': 'g1', 'permission': 'write'},
    });
  });
}
