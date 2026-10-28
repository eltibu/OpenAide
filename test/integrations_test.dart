import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/integrations_screen.dart';

class _FakeClient extends OpenWebUiClient {
  _FakeClient() : super(baseUrl: 'http://x');
  final store = <String, List<dynamic>>{
    'TOOL_SERVER_CONNECTIONS': [
      {
        'url': 'http://tools',
        'path': 'openapi.json',
        'type': 'openapi',
        'auth_type': 'bearer',
        'key': 'k',
        'config': {'enable': true, 'custom': 1},
        'info': {'id': 't', 'name': 'Tools'},
      },
    ],
    'TERMINAL_SERVER_CONNECTIONS': [],
  };

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final key = path.endsWith('tool_servers')
        ? 'TOOL_SERVER_CONNECTIONS'
        : 'TERMINAL_SERVER_CONNECTIONS';
    if (method == 'POST') store[key] = (body as Map)[key] as List;
    return {key: store[key]};
  }
}

void main() {
  test('who may use a connection keeps group grants', () {
    final c = <String, dynamic>{
      'config': {
        'access_grants': [
          {
            'principal_type': 'group',
            'principal_id': 'g',
            'permission': 'read',
          },
        ],
      },
    };
    expect(isPublicConnection(c), isFalse);
    setPublicConnection(c, true);
    expect(isPublicConnection(c), isTrue);
    setPublicConnection(c, false);
    expect((c['config'] as Map)['access_grants'], hasLength(1));
  });

  testWidgets('edits a tool server and keeps what it doesn\'t show', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final client = _FakeClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const IntegrationsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'My tools',
    );
    await tester.tap(find.text('Everyone can use it'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final saved = client.store['TOOL_SERVER_CONNECTIONS']!.single as Map;
    expect((saved['info'] as Map)['name'], 'My tools');
    expect((saved['config'] as Map)['custom'], 1);
    expect(isPublicConnection(saved.cast<String, dynamic>()), isTrue);
    expect(find.text('My tools'), findsOneWidget);

    // A terminal gets an id from its name.
    await tester.tap(find.text('Terminal servers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add connection').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'URL'),
      'http://t',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Home Box',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final term = client.store['TERMINAL_SERVER_CONNECTIONS']!.single as Map;
    expect(term['id'], 'home-box');
  });
}
