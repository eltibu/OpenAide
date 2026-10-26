// Runs against a real Open WebUI server. Skipped unless configured:
//
//   OWUI_URL=http://localhost:8080 OWUI_EMAIL=... OWUI_PASSWORD=... \
//     flutter test test/integration
//
// It creates one chat on the server and deletes it at the end.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/chat_socket.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/models/chat.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  /// Waits until the server has saved [replyId] as done.
  Future<ChatMessage> savedReply(
    OpenWebUiClient client,
    String chatId,
    String replyId,
  ) async {
    for (var i = 0; i < 60; i++) {
      final m = (await client.chat(chatId)).messages[replyId];
      if (m != null && (m.done || m.error != null)) return m;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw TimeoutException('reply $replyId never finished');
  }

  test(
    'the server runs, streams and saves each reply',
    () async {
      final client = OpenWebUiClient(baseUrl: url!);
      await client.signIn(email!, password!);
      expect((await client.me())['email'], email);

      final models = await client.models();
      expect(models, isNotEmpty);
      final model = models.first.id;

      final socket = ChatSocket(baseUrl: url, token: client.token!);
      final sessionId = await socket.ready(
        timeout: const Duration(seconds: 10),
      );
      expect(sessionId, isNotNull);
      final live = <Map<String, dynamic>>[];
      final sub = socket.events.listen(live.add);

      // First turn: a new chat, with live events over the socket.
      final user = ChatMessage(id: 'u-test', role: 'user', content: 'ping');
      final first = await client.startTurn(
        model: model,
        chatId: null,
        userMessage: user,
        replyId: 'a-test',
        messages: [
          {'role': 'user', 'content': 'ping'},
        ],
        sessionId: sessionId!,
      );
      final chatId = first.chatId;
      expect(chatId, isNotEmpty);

      try {
        final reply = await savedReply(client, chatId, 'a-test');
        expect(reply.error, isNull);
        expect(reply.content, isNotEmpty);
        expect(live.where((e) => e['message_id'] == 'a-test'), isNotEmpty);

        // Second turn without a live socket: still saved on the server.
        final next = ChatMessage(
          id: 'u-test-2',
          role: 'user',
          content: 'again',
          parentId: 'a-test',
        );
        await client.startTurn(
          model: model,
          chatId: chatId,
          userMessage: next,
          replyId: 'a-test-2',
          messages: [
            {'role': 'user', 'content': 'ping'},
            {'role': 'assistant', 'content': reply.content},
            {'role': 'user', 'content': 'again'},
          ],
          sessionId: 'nexus-app-test',
        );
        final second = await savedReply(client, chatId, 'a-test-2');
        expect(second.content, isNotEmpty);

        final fetched = await client.chat(chatId);
        expect(fetched.thread.map((m) => m.id), [
          'u-test',
          'a-test',
          'u-test-2',
          'a-test-2',
        ]);
        expect((await client.chats()).map((c) => c.id), contains(chatId));
      } finally {
        await sub.cancel();
        socket.dispose();
        await client.deleteChat(chatId);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
