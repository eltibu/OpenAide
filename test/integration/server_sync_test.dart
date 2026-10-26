// Runs against a real Open WebUI server. Skipped unless configured:
//
//   OWUI_URL=http://localhost:8080 OWUI_EMAIL=... OWUI_PASSWORD=... \
//     flutter test test/integration
//
// It creates one chat on the server and deletes it at the end.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/models/chat.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test(
    'chat round-trips through the server',
    () async {
      final client = OpenWebUiClient(baseUrl: url!);
      await client.signIn(email!, password!);
      expect((await client.me())['email'], email);

      final models = await client.models();
      expect(models, isNotEmpty);
      final model = models.first.id;

      final user = ChatMessage(id: 'u-test', role: 'user', content: 'ping');
      final created = await client.createChat(
        Chat(id: '', title: 'New Chat', messages: {}, models: [model])
          ..append(user),
      );
      expect(created.id, isNotEmpty);

      try {
        final reply = await client
            .streamCompletion(
              model: model,
              messages: [
                {'role': 'user', 'content': 'ping'},
              ],
            )
            .join();
        expect(reply, isNotEmpty);

        created.append(
          ChatMessage(
            id: 'a-test',
            role: 'assistant',
            content: reply,
            parentId: 'u-test',
            model: model,
          ),
        );
        created.title =
            await client.generateTitle(model, [
              {'role': 'user', 'content': 'ping'},
              {'role': 'assistant', 'content': reply},
            ]) ??
            'Untitled';
        await client.saveChat(created);

        final fetched = await client.chat(created.id);
        expect(fetched.thread.map((m) => m.content), ['ping', reply]);
        expect(fetched.title, created.title);
        expect((await client.chats()).map((c) => c.id), contains(created.id));
      } finally {
        await client.deleteChat(created.id);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
