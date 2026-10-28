import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/integrations_screen.dart';

class _FakeClient extends OpenWebUiClient {
  _FakeClient() : super(baseUrl: 'http://x');
  final calls = <(String, Map<String, String>?, Object?)>[];

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    calls.add((path, query, body));
    return {
      'status': true,
      'oauth_client_info': {'client_id': 'abc'},
    };
  }
}

void main() {
  test('a connection exports as the web does and imports back', () {
    final c = <String, dynamic>{
      'type': 'mcp',
      'url': 'https://mcp.example/mcp',
      'auth_type': 'oauth_2.1',
      'config': {
        'enable': true,
        'access_grants': [
          {'principal_id': '*'},
        ],
      },
      'info': {
        'id': 'ex',
        'name': 'Example',
        'oauth_scope': 'read',
        'oauth_client_info': {'secret': 's'},
      },
    };
    final out = jsonDecode(exportConnection(c)) as List;
    expect(out, hasLength(1));
    expect(out.first['url'], 'https://mcp.example/mcp');
    expect(out.first['info'], {
      'id': 'ex',
      'name': 'Example',
      'oauth_scope': 'read',
    });
    expect(out.first.containsKey('config'), isFalse);

    final into = <String, dynamic>{
      'config': {
        'access_grants': [
          {'principal_id': 'g'},
        ],
      },
    };
    importConnection(into, exportConnection(c));
    expect(into['type'], 'mcp');
    expect((into['info'] as Map)['oauth_scope'], 'read');
    expect((into['config'] as Map)['access_grants'], hasLength(1));
    expect(() => importConnection(into, '[]'), throwsFormatException);
    expect(slugId('My MCP Server!'), 'my-mcp-server');
  });

  testWidgets('registers an OAuth client before saving', (tester) async {
    tester.view.physicalSize = const Size(1080, 5000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final client = _FakeClient();
    Object? saved;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => saved = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ServerEditor(
                    kind: toolServerKind,
                    isNew: true,
                    connection: {
                      'type': 'mcp',
                      'url': 'https://mcp.example/mcp',
                      'auth_type': 'oauth_2.1',
                      'info': {'name': 'My Server'},
                    },
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Check OAuth discovery'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Register the OAuth client first'), findsOneWidget);
    expect(saved, isNull);

    await tester.tap(find.text('Register client'));
    await tester.pumpAndSettle();
    final (path, query, body) = client.calls.single;
    expect(path, '/api/v1/configs/oauth/clients/register');
    expect(query, {'type': 'mcp'});
    expect(body, {'url': 'https://mcp.example/mcp', 'client_id': 'my-server'});
    expect(find.text("OAuth client registered"), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final info = (saved as Map)['info'] as Map;
    expect(info['id'], 'my-server');
    expect(info['oauth_client_info'], {'client_id': 'abc'});
  });
}
