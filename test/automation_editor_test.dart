import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/models/model_info.dart';
import 'package:nexus_assistant/features/automations/automations_api.dart';
import 'package:nexus_assistant/features/automations/automations_screen.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/chat/chat_drawer.dart';
import 'package:nexus_assistant/features/terminal/terminal_api.dart';
import 'package:nexus_assistant/features/terminal/terminal_screen.dart';

class _FakeApi extends AutomationsApi {
  _FakeApi() : super(OpenWebUiClient(baseUrl: 'http://x'));
  final saved = <(String?, Map<String, dynamic>)>[];

  @override
  Future<Automation> save(String? id, Map<String, dynamic> form) async {
    saved.add((id, form));
    return Automation.fromJson({'id': 'new', ...form});
  }
}

void main() {
  testWidgets('duplicating keeps everything as a new automation', (
    tester,
  ) async {
    final api = _FakeApi();
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final source = Automation.fromJson({
      'id': 'a1',
      'name': 'Morning news',
      'is_active': true,
      'data': {
        'prompt': 'Summarise the news',
        'model_id': 'nexus',
        'rrule': 'RRULE:FREQ=DAILY;BYHOUR=8;BYMINUTE=0',
        'target': {'type': 'chat'},
        'terminal': {'server_id': 't1', 'cwd': '/work'},
      },
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          modelsProvider.overrideWith(
            (ref) async => [ModelInfo(id: 'nexus', name: 'Nexus', raw: {})],
          ),
          channelsProvider.overrideWith((ref) async => const []),
          foldersProvider.overrideWith((ref) async => const []),
          terminalServersProvider.overrideWith(
            (ref) async => const [TerminalServer(id: 't1', name: 'Box')],
          ),
        ],
        child: MaterialApp(
          home: AutomationEditor(api: api, copyOf: source),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New automation'), findsOneWidget);
    expect(find.text('Morning news (copy)'), findsOneWidget);
    expect(find.text('Box'), findsOneWidget);
    expect(find.text('/work'), findsOneWidget);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    final (id, form) = api.saved.single;
    expect(id, isNull);
    expect(form['name'], 'Morning news (copy)');
    final data = form['data'] as Map;
    expect(data['prompt'], 'Summarise the news');
    expect(data['model_id'], 'nexus');
    expect(data['terminal'], {'server_id': 't1', 'cwd': '/work'});
  });
}
