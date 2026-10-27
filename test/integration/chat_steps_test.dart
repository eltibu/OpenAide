// Runs against a real Open WebUI server; see server_sync_test.dart. With the
// test's fake model: "think" streams thinking first, "slow" writes slowly,
// and its text to speech answers with a short sound.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/chat/read_aloud.dart';
import 'package:nexus_assistant/features/chat/reply_parts.dart';

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

  test('live thinking steps, read aloud, fork and steer', () async {
    HttpOverrides.global = null;
    final played = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = Directory.systemTemp.createTempSync('speech');
    messenger.setMockMethodCallHandler(const MethodChannel('nexus/speech'), (
      call,
    ) async {
      if (call.method == 'dir') return dir.path;
      if (call.method == 'play') {
        played.add((call.arguments as Map)['path'] as String);
        return 'done';
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
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
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!container.read(chatControllerProvider).streaming) return;
      }
      fail('The reply never finished');
    }

    try {
      await container.read(readAloudOnProvider.notifier).set(true);

      // Thinking shows as a step while the reply runs.
      var sawThinking = false;
      final sub = container.listen(chatControllerProvider, (_, s) {
        final last = s.messages.lastOrNull;
        if (s.streaming && last != null && last.role == 'assistant') {
          if (replyParts(
            last,
            live: true,
          ).any((p) => p is ThinkingPart && p.text.contains('think'))) {
            sawThinking = true;
          }
        }
      });
      await controller.send('Please think about this question');
      await settle();
      sub.close();
      final state = container.read(chatControllerProvider);
      chats.add(state.chat!.id);
      expect(state.error, isNull);
      expect(sawThinking, isTrue);
      final parts = replyParts(state.messages.last);
      expect(parts.first, isA<ThinkingPart>());
      expect((parts.whereType<TextPart>().single).text, startsWith('You said'));

      // Read aloud spoke the reply.
      for (var i = 0; i < 50 && played.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(played, isNotEmpty);

      // Fork: a new chat with the conversation so far.
      final original = state.chat!.id;
      await controller.fork(state.messages.last);
      final forked = container.read(chatControllerProvider).chat!;
      chats.add(forked.id);
      expect(forked.id, isNot(original));
      expect(forked.title, endsWith('(fork)'));
      expect(forked.thread.map((m) => m.role), ['user', 'assistant']);
      expect((await client.chat(original)).thread, hasLength(2));

      // Steer: stop a slow reply and send something else.
      await container.read(readAloudOnProvider.notifier).set(false);
      unawaited(controller.send('Write slow please'));
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final s = container.read(chatControllerProvider);
        if (s.streaming && s.messages.last.content.length > 20) break;
      }
      expect(container.read(chatControllerProvider).streaming, isTrue);
      await controller.steer('Short one');
      await settle();
      final thread = container.read(chatControllerProvider).messages;
      expect(thread.map((m) => m.role), [
        'user',
        'assistant',
        'user',
        'assistant',
        'user',
        'assistant',
      ]);
      expect(thread[3].content, startsWith('word'));
      expect(thread[3].content.split(' ').length, lessThan(150));
      expect(thread.last.content, contains('Short one'));
    } finally {
      await container.read(readAloudOnProvider.notifier).set(false);
      for (final id in chats) {
        await client.deleteChat(id);
      }
    }
  }, skip: skip);
}
