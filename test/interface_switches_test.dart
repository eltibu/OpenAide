import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/chat/artifacts_view.dart';
import 'package:nexus_assistant/features/chat/chat_extras.dart';

void main() {
  test('artifact pages follow the forms and downloads switches', () {
    final both = artifactGuards(forms: true, downloads: true);
    expect(both, isNot(contains("'submit'")));
    expect(both, contains('NexusDownload'));
    final none = artifactGuards(forms: false, downloads: false);
    expect(none, contains("'submit'"));
    expect(none, isNot(contains('NexusDownload')));
  });

  test('a download from a page becomes a file', () {
    final (name, bytes) = downloadFromPage(
      jsonEncode({
        'name': 'notes.txt',
        'data': 'data:text/plain;base64,${base64Encode(utf8.encode('hi'))}',
      }),
    );
    expect(name, 'notes.txt');
    expect(utf8.decode(bytes), 'hi');
    final (other, plain) = downloadFromPage(
      jsonEncode({'name': '', 'data': 'data:text/csv,a%2Cb'}),
    );
    expect(other, 'download');
    expect(utf8.decode(plain), 'a,b');
  });

  test('a plain chat PDF is made', () async {
    final chat = Chat.fromServer({
      'id': 'c',
      'title': 'Hi',
      'chat': {
        'history': {
          'currentId': 'b',
          'messages': {
            'a': {'id': 'a', 'role': 'user', 'content': 'Hello'},
            'b': {
              'id': 'b',
              'parentId': 'a',
              'role': 'assistant',
              'content': 'Hi **there**',
            },
          },
        },
      },
    });
    final pdf = await plainChatPdf(chat);
    expect(String.fromCharCodes(pdf.take(4)), '%PDF');
  });
}
