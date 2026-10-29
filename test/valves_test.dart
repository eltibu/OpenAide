import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/workspace/tools_skills.dart';

class _FakeClient extends OpenWebUiClient {
  _FakeClient() : super(baseUrl: 'http://x');
  Object? saved;

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (path.endsWith('/spec')) {
      return {
        'properties': {
          'city': {'type': 'string', 'title': 'City', 'default': 'Paris'},
          'units': {
            'type': 'string',
            'title': 'Units',
            'enum': ['c', 'f'],
          },
        },
      };
    }
    if (method == 'GET') return {'units': 'f'};
    saved = body;
    return {};
  }
}

void main() {
  testWidgets('valves stay on Default until made Custom', (tester) async {
    final client = _FakeClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const ValvesScreen(
            title: 'Weather',
            specPath: '/t/valves/user/spec',
            valuesPath: '/t/valves/user',
            savePath: '/t/valves/user/update',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // City has no value of yours: Default. Units was set: Custom.
    expect(find.text('Custom'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Default'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(client.saved, {'city': null, 'units': 'f'});
  });
}
