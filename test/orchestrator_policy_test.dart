import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/integrations_screen.dart';
import 'package:nexus_assistant/features/admin/orchestrator_policy.dart';

class _FakeClient extends OpenWebUiClient {
  _FakeClient() : super(baseUrl: 'http://x');
  final calls = <(String, Object?)>[];

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    calls.add((path, body));
    if (path.endsWith('/verify')) return {'type': 'orchestrator'};
    return {'data': {}};
  }
}

void main() {
  test('policy data, environment lines and contexts', () {
    final p = OrchestratorPolicy(id: 'p')
      ..image = 'img:1'
      ..persistent = true
      ..storageSize = '10Gi'
      ..env = 'A=1\nB=x=y\n=skip\nnope';
    expect(p.data(), {
      'image': 'img:1',
      'cpu_limit': '1',
      'memory_limit': '1Gi',
      'storage': '10Gi',
      'idle_timeout_minutes': 30,
      'env': {'A': '1', 'B': 'x=y'},
    });
    final q = OrchestratorPolicy()..fill(p.data());
    expect(q.env, 'A=1\nB=x=y');
    expect(q.persistent, isTrue);
    expect(() => (q..lifecycle = '[]').lifecycleData(), throwsFormatException);

    final config = <String, dynamic>{};
    setContexts(config, 'chat_id', 'off');
    expect(contextMode(config, 'chat'), 'chat_id');
    expect(contextMode(config, 'automation'), 'off');
    setContexts(config, 'default', 'default');
    expect(config.containsKey('contexts'), isFalse);
  });

  testWidgets('an orchestrator saves its policy with the connection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 6000);
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
                    kind: terminalServerKind,
                    isNew: true,
                    connection: {
                      'url': 'http://orch/',
                      'name': 'Team Shells',
                      'key': ' k ',
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
    expect(find.text('Orchestrator'), findsNothing);
    await tester.tap(find.text('Check connection'));
    await tester.pumpAndSettle();
    expect(find.text('Orchestrator'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Image'),
      'ghcr.io/x/term:1',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final policy = client.calls.firstWhere((c) => c.$1.endsWith('/policy'));
    expect(policy.$2, {
      'url': 'http://orch',
      'key': 'k',
      'auth_type': 'bearer',
      'policy_id': 'team-shells',
      'policy_data': {
        'image': 'ghcr.io/x/term:1',
        'cpu_limit': '1',
        'memory_limit': '1Gi',
        'idle_timeout_minutes': 30,
      },
    });
    expect(client.calls.last.$1, endsWith('/lifecycle'));
    final c = saved as Map;
    expect(c['policy_id'], 'team-shells');
    expect(c['server_type'], 'orchestrator');
  });
}
