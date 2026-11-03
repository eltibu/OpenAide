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

  test(
    'several models answer, switch between them, merge',
    () async {
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
      expect(models.map((m) => m.id), containsAll(['fake', 'fake2']));
      final controller = container.read(chatControllerProvider.notifier)
        ..selectModel('fake')
        ..setCompare(['fake2']);
      ChatState now() => container.read(chatControllerProvider);

      await controller.send('Hello both');
      expect(now().error, isNull);
      final user = now().messages.first;
      final answers = controller.answersTo(user);
      expect(answers.map((a) => a.model), ['fake', 'fake2']);
      expect(answers[0].content, contains('You said: Hello both'));
      expect(answers[1].content, contains('Fake2 says: Hello both'));
      expect(now().messages.last.model, 'fake');

      // Saved on the server the way the web saves them.
      final saved = await client.chat(now().chat!.id);
      expect(saved.models, ['fake', 'fake2']);
      expect(saved.messages[user.id]!.childrenIds, hasLength(2));

      await controller.showAnswer(answers[1]);
      expect(now().messages.last.model, 'fake2');

      await controller.merge(now().messages.last);
      expect(now().error, isNull);
      final merged = now().messages.last.extra['merged'] as Map;
      expect('${merged['content']}', isNotEmpty);
      final again = await client.chat(now().chat!.id);
      expect(again.currentId, answers[1].id);
      expect(
        (again.messages[answers[1].id]!.extra['merged'] as Map)['content'],
        merged['content'],
      );

      // Opening the chat again keeps comparing with the same models.
      controller
        ..newChat()
        ..setCompare(const []);
      await controller.open(saved.id);
      expect(now().compareIds, ['fake2']);
      await client.deleteChat(saved.id);

      // "@" a model: since Open WebUI 0.12.5 it answers and the chat
      // carries on with it, saved with the chat.
      controller
        ..newChat()
        ..selectModel('fake')
        ..setCompare(const []);
      container.read(atModelProvider.notifier).set('fake2');
      await controller.send('Just you');
      expect(now().messages.last.model, 'fake2');
      expect(container.read(atModelProvider), isNull);
      expect(now().modelId, 'fake2');
      await controller.send('And now');
      expect(now().messages.last.model, 'fake2');
      expect((await client.chat(now().chat!.id)).models, ['fake2']);
      await client.deleteChat(now().chat!.id);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
