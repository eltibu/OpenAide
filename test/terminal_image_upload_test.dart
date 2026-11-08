import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_assistant/core/api/chat_socket.dart';
import 'package:nexus_assistant/features/settings/tool_servers.dart';

// A generated image goes into the chat's own terminal folder: the server
// asks the phone to copy it there, as the web's browser does.
void main() {
  const ui = {
    'terminalServers': [
      {'url': 'https://term.example', 'key': 'k', 'enabled': true},
      {'url': 'https://off.example', 'key': 'k', 'enabled': false},
    ],
  };

  SocketCall ask(Map<String, dynamic> body, void Function(Object?) answer) =>
      SocketCall({
        'chat_id': 'chat1',
        'data': {'type': 'request:terminal', 'data': body},
      }, answer);

  test('copies the image to the terminal folder', () async {
    http.Request? sent;
    final client = MockClient((req) async {
      sent = req;
      return http.Response(
        jsonEncode({'path': '/home/user/img1.png'}),
        200,
      );
    });
    Object? answer;
    String? asked;
    await answerTerminalRequest(
      ask({
        'terminal_id': 'https://term.example',
        'path': '/files/upload?directory=%2Fhome%2Fuser',
        'file': {'id': 'img1', 'name': 'img1.png'},
      }, (v) => answer = v),
      ui: ui,
      serverUrl: 'https://owui.example',
      sessionToken: 't',
      systemTerminal: false,
      fileBytes: (id) async {
        asked = id;
        return [1, 2, 3];
      },
      httpClient: client,
    );
    expect(asked, 'img1');
    expect(sent!.method, 'POST');
    expect(
      sent!.url.toString(),
      'https://term.example/files/upload?directory=%2Fhome%2Fuser',
    );
    expect(sent!.headers['Authorization'], 'Bearer k');
    expect(sent!.headers['X-Session-Id'], 'chat1');
    expect(sent!.headers['content-type'], startsWith('multipart/form-data'));
    expect(latin1.decode(sent!.bodyBytes), contains('filename="img1.png"'));
    expect(answer, {
      'data': {'path': '/home/user/img1.png'},
    });
  });

  test('still reads JSON when no file comes', () async {
    final client = MockClient((req) async {
      expect(req.method, 'GET');
      return http.Response(jsonEncode({'cwd': '/home/user'}), 200);
    });
    Object? answer;
    await answerTerminalRequest(
      ask({
        'terminal_id': 'https://term.example',
        'path': '/files/cwd',
      }, (v) => answer = v),
      ui: ui,
      serverUrl: 'https://owui.example',
      sessionToken: 't',
      systemTerminal: false,
      httpClient: client,
    );
    expect(answer, {
      'data': {'cwd': '/home/user'},
    });
  });

  test('a terminal switched off is not reached', () async {
    final client = MockClient((_) async => fail('should not be reached'));
    Object? answer;
    await answerTerminalRequest(
      ask({
        'terminal_id': 'https://off.example',
        'path': '/files/cwd',
      }, (v) => answer = v),
      ui: ui,
      serverUrl: 'https://owui.example',
      sessionToken: 't',
      systemTerminal: false,
      httpClient: client,
    );
    expect(answer, {'error': 'Terminal Not Found'});
  });
}
