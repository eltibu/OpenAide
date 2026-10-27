// Runs against a real Open WebUI server; see server_sync_test.dart. Needs
// Tool Permissions on (Admin > Settings > Chat), "ask" as the person's tool
// approval mode, native function calling, and the test's fake model: it
// calls ask_user for "ask me" and get_current_timestamp for "time", and
// answers a tool result with "Tool said: …".
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/chat/tool_approval.dart';

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

  test('a paused reply: answer its question, allow or deny its tool', () async {
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
    final models = await container.read(modelsProvider.future);
    await container.read(userSettingsProvider.future);
    final controller = container.read(chatControllerProvider.notifier)
      ..selectModel(models.first.id);
    final chats = <String>{};
    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      for (var i = 0; i < 300; i++) {
        if (!container.read(chatControllerProvider).streaming) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      fail('The reply never finished');
    }

    ChatMessage last() => container.read(chatControllerProvider).messages.last;

    try {
      // The model asks a question; the answer carries the reply on.
      await controller.send('Please ask me something');
      await settle();
      chats.add(container.read(chatControllerProvider).chat!.id);
      expect(container.read(chatControllerProvider).error, isNull);
      var waiting = pendingCall(last());
      expect(waiting?.asksUser, isTrue);
      final q = waiting!.questions.single;
      expect(q.options.map((o) => o.label), ['Red', 'Blue']);
      await controller.resolveTool(
        last(),
        waiting.callId,
        'answer',
        answers: {
          q.id: {
            'type': 'option',
            'option_index': 1,
            'label': 'Blue',
            'description': '',
          },
        },
      );
      await settle();
      expect(container.read(chatControllerProvider).error, isNull);
      expect(pendingCall(last()), isNull);
      expect(last().done, isTrue);
      expect(last().content, contains('Tool said'));
      expect(last().content, contains('Blue'));

      // A tool waits for Allow.
      await controller.send('What time is it?');
      await settle();
      waiting = pendingCall(last());
      expect(waiting?.name, 'get_current_timestamp');
      await controller.resolveTool(last(), waiting!.callId, 'approve');
      await settle();
      expect(pendingCall(last()), isNull);
      expect(last().done, isTrue);
      expect(last().content, contains('Tool said'));

      // Deny: the tool doesn't run and the reply still finishes.
      await controller.send('The time once more');
      await settle();
      waiting = pendingCall(last());
      expect(waiting?.name, 'get_current_timestamp');
      await controller.resolveTool(last(), waiting!.callId, 'reject');
      await settle();
      expect(pendingCall(last()), isNull);
      expect(last().done, isTrue);
      final output = (last().extra['output'] as List).whereType<Map>();
      expect(
        output.any(
          (i) => i['type'] == 'function_call' && i['status'] == 'rejected',
        ),
        isTrue,
      );
    } finally {
      for (final id in chats) {
        await client.deleteChat(id);
      }
    }
  }, skip: skip);
}
