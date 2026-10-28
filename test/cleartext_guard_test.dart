import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/net/local_network.dart';

/// Open WebUI that answers only over plain http, wherever it lives.
final _httpOnly = MockClient((req) async {
  if (req.url.scheme == 'https') throw http.ClientException('TLS failed');
  if (req.url.path.endsWith('/api/config')) {
    return http.Response(jsonEncode({'name': 'Open WebUI'}), 200);
  }
  return http.Response('<!doctype html><html></html>', 200);
});

void main() {
  test('home network names and addresses are local', () {
    for (final h in [
      'localhost',
      '192.168.1.209',
      '10.0.0.5',
      '[::1]',
      'nas',
      'server.local',
      'box.lan',
      'pi.home.arpa',
    ]) {
      expect(isLocalHost(h), isTrue, reason: h);
    }
    for (final h in ['chat.example.com', '8.8.8.8', 'openwebui.app']) {
      expect(isLocalHost(h), isFalse, reason: h);
    }
  });

  test('only plain http to the internet counts as insecure', () {
    expect(isInsecureRemote(Uri.parse('http://chat.example.com')), isTrue);
    expect(isInsecureRemote(Uri.parse('https://chat.example.com')), isFalse);
    expect(isInsecureRemote(Uri.parse('http://192.168.1.209/chat')), isFalse);
  });

  test('plain http on the home network still connects', () async {
    expect(
      await OpenWebUiClient.discover(
        'http://192.168.1.20/chat',
        httpClient: _httpOnly,
      ),
      'http://192.168.1.20/chat',
    );
  });

  test('plain http to the internet needs the person to agree', () async {
    await expectLater(
      OpenWebUiClient.discover('chat.example.com', httpClient: _httpOnly),
      throwsA(
        isA<InsecureServer>().having((e) => e.host, 'host', 'chat.example.com'),
      ),
    );
    expect(
      await OpenWebUiClient.discover(
        'chat.example.com',
        httpClient: _httpOnly,
        allowInsecure: {'chat.example.com'},
      ),
      'http://chat.example.com',
    );
  });

  test('a wrong address is not blamed on http', () async {
    final none = MockClient((_) async => throw http.ClientException('no'));
    await expectLater(
      OpenWebUiClient.discover('nowhere.example.com', httpClient: none),
      throwsA(isA<ApiException>()),
    );
  });
}
