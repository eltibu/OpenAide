// Runs against a real Open WebUI server; see tool_approval_test.dart. Your
// own connection is the test's fake OpenAI server (OLLAMA_URL's sibling at
// FAKE_OPENAI_URL, default http://127.0.0.1:11500/v1): its models join the
// list, and a chat with one goes from the server back to this "phone",
// which sends it and passes the reply on.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/admin/connections_screen.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/settings/direct_connections.dart';

class _Session extends SessionNotifier {
  _Session(this.session);
  final Session session;
  @override
  Future<Session?> build() async => session;
}

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final fake =
      Platform.environment['FAKE_OPENAI_URL'] ?? 'http://127.0.0.1:11500/v1';
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  TestWidgetsFlutterBinding.ensureInitialized();

  test('a chat with your own connection runs from the phone', () async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final before = await client.send('GET', '/api/v1/configs/connections');
    await client.send(
      'POST',
      '/api/v1/configs/connections',
      body: {...before as Map, 'ENABLE_DIRECT_CONNECTIONS': true},
    );
    final settings = await client.userSettings();
    final ui = Map<String, dynamic>.of((settings['ui'] as Map?)?.cast() ?? {});
    final saved = ui[directConnectionsKey];
    final mine = Connection(url: fake, key: 'k', config: {'prefix_id': 'me'});
    ui[directConnectionsKey] = writeConnections(openAiConnections, true, [
      mine,
    ])..remove(openAiConnections.enableKey);
    await client.send(
      'POST',
      '/api/v1/users/user/settings/update',
      body: {...settings, 'ui': ui},
    );
    addTearDown(() async {
      if (saved == null) {
        ui.remove(directConnectionsKey);
      } else {
        ui[directConnectionsKey] = saved;
      }
      await client.send(
        'POST',
        '/api/v1/users/user/settings/update',
        body: {...settings, 'ui': ui},
      );
      await client.send('POST', '/api/v1/configs/connections', body: before);
    });

    expect(await checkConnection(mine), isNull);
    expect(
      await checkConnection(Connection(url: 'http://127.0.0.1:9/v1')),
      isNotNull,
    );

    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(
          () => _Session(Session(serverUrl: url, token: client.token!)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    final models = await container.read(modelsProvider.future);
    final direct = models.firstWhere((m) => m.id == 'me.fake');
    expect(direct.raw['direct'], isTrue);
    expect(direct.raw['urlIdx'], '0');

    // ServerAsks answers request:chat:completion in the app; here the test
    // wires the same handler.
    final socket = container.read(chatSocketProvider);
    await socket.ready(timeout: const Duration(seconds: 10));
    var asked = 0;
    final sub = socket.calls.listen((c) {
      if (c.type == 'request:chat:completion') {
        asked++;
        runDirectCompletion(c, [mine], socket.emit);
      }
    });
    addTearDown(sub.cancel);

    final controller = container.read(chatControllerProvider.notifier)
      ..selectModel(direct.id)
      ..newChat(temporary: true);
    await controller.send('Say hello');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    for (var i = 0; i < 300; i++) {
      if (!container.read(chatControllerProvider).streaming) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final reply = container.read(chatControllerProvider).messages.last;
    expect(reply.role, 'assistant');
    expect(reply.content, isNotEmpty);
    expect(asked, greaterThan(0));
  }, skip: skip);
}
