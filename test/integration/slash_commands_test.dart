// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';

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
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  TestWidgetsFlutterBinding.ensureInitialized();

  test('/compact and /status context usage', () async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(
          () => _Session(Session(serverUrl: url, token: client.token!)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    await container.read(modelsProvider.future);
    final controller = container.read(chatControllerProvider.notifier)
      ..selectModel('fake');

    final config = (await client.send('GET', '/api/v1/chats/config') as Map)
        .cast<String, dynamic>();
    Future<void> compaction(bool on) => client.send(
      'POST',
      '/api/v1/chats/config',
      body: {...config, 'ENABLE_CONTEXT_COMPACTION': on},
    );
    addTearDown(() => compaction(config['ENABLE_CONTEXT_COMPACTION'] == true));

    await compaction(false);
    await controller.send('hello');
    // The server may still be writing a title; /compact says to wait.
    Future<String?> compact() async {
      for (var i = 0; i < 40; i++) {
        final why = await controller.compact();
        if (why == null || !why.startsWith('Wait')) return why;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return controller.compact();
    }

    expect(await compact(), 'Context compaction is disabled');
    expect(await controller.contextUsage(), isNull);

    await compaction(true);
    final usage = await controller.contextUsage();
    expect(usage?['tokens'], isA<num>());
    expect(usage?['threshold'], isA<num>());
    expect(await compact(), anyOf(isNull, 'Chat is too short to compact'));
    // The chat is reloaded, still there and still answering.
    expect(container.read(chatControllerProvider).chat?.id, isNotEmpty);
    await controller.send('after');
    expect(
      container.read(chatControllerProvider).messages.last.role,
      'assistant',
    );
  }, skip: skip);
}
