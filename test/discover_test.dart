import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';

/// Fake server: Open WebUI at http://home.lan:3000 that, like the real one,
/// serves its HTML app for any unknown path.
final _server = MockClient((req) async {
  if (req.url.scheme == 'https' && req.url.host == 'home.lan') {
    throw http.ClientException('TLS failed');
  }
  if (req.url.host == 'proxied.lan') {
    // Reverse proxy that redirects http to https, as nginx/Caddy often do.
    if (req.url.scheme == 'http') {
      return http.Response(
        '<html>301 Moved</html>',
        301,
        headers: {'location': 'https://proxied.lan${req.url.path}'},
      );
    }
    if (req.url.path == '/api/config') {
      return http.Response(jsonEncode({'name': 'Open WebUI'}), 200);
    }
    return http.Response('{"token":"t"}', 200);
  }
  if (req.url.host != 'home.lan') throw http.ClientException('no route');
  if (req.url.path == '/api/config') {
    return http.Response(
      jsonEncode({'name': 'Open WebUI', 'version': '0.12.4'}),
      200,
    );
  }
  return http.Response('<!doctype html><html></html>', 200);
});

void main() {
  test('strips a pasted chat path and falls back to http', () async {
    expect(
      await OpenWebUiClient.discover(
        'home.lan:3000/c/abc123',
        httpClient: _server,
      ),
      'http://home.lan:3000',
    );
  });

  test('keeps an address that already works', () async {
    expect(
      await OpenWebUiClient.discover(
        'http://home.lan:3000/',
        httpClient: _server,
      ),
      'http://home.lan:3000',
    );
  });

  test(
    'an HTML answer becomes a readable error, not a FormatException',
    () async {
      final client = OpenWebUiClient(
        baseUrl: 'http://home.lan:3000',
        httpClient: _server,
      );
      expect(
        () => client.me(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.toString(),
            'message',
            contains('web page instead of Open WebUI'),
          ),
        ),
      );
    },
  );

  test('follows an http to https redirect', () async {
    expect(
      await OpenWebUiClient.discover('http://proxied.lan', httpClient: _server),
      'https://proxied.lan',
    );
  });

  test(
    'a redirect on sign-in is a readable error, not a FormatException',
    () async {
      final client = OpenWebUiClient(
        baseUrl: 'http://proxied.lan',
        httpClient: _server,
      );
      expect(
        () => client.signIn('a@b.c', 'pw'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.redirectTo.toString(),
            'redirectTo',
            'https://proxied.lan/api/v1/auths/signin',
          ),
        ),
      );
    },
  );
}
