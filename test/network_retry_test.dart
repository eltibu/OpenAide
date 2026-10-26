import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';

void main() {
  test('a brief DNS failure is retried', () async {
    var calls = 0;
    final client = OpenWebUiClient(
      baseUrl: 'https://chat.example.com',
      httpClient: MockClient((req) async {
        if (++calls == 1) {
          throw http.ClientException(
            "SocketException: Failed host lookup: 'chat.example.com'",
          );
        }
        return http.Response(jsonEncode({'name': 'Joel'}), 200);
      }),
    );
    expect((await client.me())['name'], 'Joel');
    expect(calls, 2);
  });

  test('a lasting outage becomes a readable error', () async {
    final client = OpenWebUiClient(
      baseUrl: 'https://chat.example.com',
      httpClient: MockClient((req) async {
        throw http.ClientException('Failed host lookup');
      }),
    );
    expect(
      () => client.me(),
      throwsA(
        isA<ApiException>().having(
          (e) => e.toString(),
          'message',
          contains("Can't reach chat.example.com"),
        ),
      ),
    );
  });
}
