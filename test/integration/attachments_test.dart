// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/models/chat.dart';

// A 1x1 PNG.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test(
    'photos and files go with a message and stay on the server',
    () async {
      final client = OpenWebUiClient(baseUrl: url!);
      await client.signIn(email!, password!);
      final model = (await client.models()).first.id;

      final photo = Attachment.uploaded(
        await client.uploadFile(
          base64Decode(_png),
          'dot.png',
          contentType: 'image/png',
          process: false,
        ),
      );
      final doc = Attachment.uploaded(
        await client.uploadFile(
          utf8.encode('The secret word is pineapple.'),
          'notes.txt',
          contentType: 'text/plain',
        ),
      );
      // Settles either way; this test server may have no embedding model,
      // in which case the server says why instead of hanging.
      final problem = await client.waitForFile(doc.fileId!);
      expect(problem == null || problem.isNotEmpty, isTrue);
      expect(photo.isImage, isTrue);
      expect(doc.isImage, isFalse);

      // The photo's bytes come back from where the app shows it from.
      final bytes = await http.get(
        client.fileContentUri(photo.fileId!),
        headers: client.authHeaders,
      );
      expect(bytes.statusCode, 200);
      expect(bytes.bodyBytes, base64Decode(_png));

      final user = ChatMessage(
        id: 'u-files',
        role: 'user',
        content: 'what is in these',
        extra: {
          'files': [photo.toJson(), doc.toJson()],
        },
      );
      final started = await client.startTurn(
        model: model,
        chatId: null,
        userMessage: user,
        replyId: 'a-files',
        messages: [
          {'role': 'user', 'content': 'what is in these'},
        ],
        sessionId: 'nexus-test',
        options: {
          'files': [doc.toJson()],
        },
      );
      try {
        ChatMessage? reply;
        for (var i = 0; i < 60; i++) {
          reply = (await client.chat(started.chatId)).messages['a-files'];
          if (reply != null && (reply.done || reply.error != null)) break;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        expect(reply?.error, isNull);
        expect(reply?.content, isNotEmpty);

        final saved = (await client.chat(started.chatId)).messages['u-files']!;
        expect(saved.attachments.map((a) => a.name), ['dot.png', 'notes.txt']);
        expect(saved.attachments.first.isImage, isTrue);
      } finally {
        await client.deleteChat(started.chatId);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
