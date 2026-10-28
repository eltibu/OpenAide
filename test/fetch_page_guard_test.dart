import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_assistant/core/agent/web_tools.dart';

void main() {
  Future<List<InternetAddress>> public(String host) async => [
    InternetAddress('93.184.215.14'),
  ];

  test('home network and phone addresses count as local', () {
    for (final a in [
      '127.0.0.1',
      '10.0.0.8',
      '172.20.1.1',
      '192.168.1.209',
      '169.254.1.1',
      '100.100.1.1',
      '0.0.0.0',
      '::1',
      '::',
      'fd12::1',
      'fe80::1',
      '::ffff:192.168.1.1',
    ]) {
      expect(isLocalAddress(InternetAddress(a)), isTrue, reason: a);
    }
    for (final a in ['8.8.8.8', '172.32.0.1', '2606:4700::1111']) {
      expect(isLocalAddress(InternetAddress(a)), isFalse, reason: a);
    }
  });

  test('reading a page on the home network is refused', () async {
    var asked = false;
    final client = MockClient((_) async {
      asked = true;
      return http.Response('router', 200);
    });
    for (final url in [
      'http://192.168.1.1/admin',
      'http://localhost:8080/',
      'http://[::1]/',
    ]) {
      await expectLater(
        fetchPage(url, httpClient: client, lookup: public),
        throwsA(isA<Exception>()),
      );
    }
    await expectLater(
      fetchPage(
        'https://home.example/',
        httpClient: client,
        lookup: (_) async => [InternetAddress('10.0.0.2')],
      ),
      throwsA(isA<Exception>()),
    );
    expect(asked, isFalse);
  });

  test('a redirect to the home network is refused', () async {
    final seen = <String>[];
    final client = MockClient((req) async {
      seen.add(req.url.toString());
      return http.Response(
        '',
        302,
        headers: {'location': 'http://192.168.1.1/'},
      );
    });
    await expectLater(
      fetchPage('https://example.com/', httpClient: client, lookup: public),
      throwsA(isA<Exception>()),
    );
    expect(seen, ['https://example.com/']);
  });

  test('public pages still read, following redirects', () async {
    final client = MockClient((req) async {
      if (req.url.path == '/old') {
        return http.Response('', 301, headers: {'location': '/new'});
      }
      return http.Response(
        '<html><title>Hi</title><body>Hello</body></html>',
        200,
        headers: {'content-type': 'text/html'},
      );
    });
    final text = await fetchPage(
      'https://example.com/old',
      httpClient: client,
      lookup: public,
    );
    expect(text, contains('# Hi'));
    expect(text, contains('https://example.com/new'));
    expect(text, contains('Hello'));
  });

  test('a name that does not resolve is refused, not let through', () async {
    var asked = false;
    final client = MockClient((_) async {
      asked = true;
      return http.Response('x', 200);
    });
    await expectLater(
      fetchPage(
        'https://nowhere.example/',
        httpClient: client,
        lookup: (h) async => throw SocketException('no such host $h'),
      ),
      throwsA(isA<Exception>()),
    );
    expect(asked, isFalse);
  });

  test('a huge page is cut off instead of filling memory', () async {
    final client = MockClient.streaming(
      (req, _) async => http.StreamedResponse(
        Stream.fromIterable(
          List.generate(64, (_) => List.filled(64 * 1024, 0x61)),
        ),
        200,
        headers: {'content-type': 'text/plain'},
      ),
    );
    final text = await fetchPage(
      'https://example.com/big',
      httpClient: client,
      lookup: public,
    );
    expect(text.length, 2 * 1024 * 1024);
  });

  test('a file is turned away without downloading it', () async {
    var read = false;
    final client = MockClient.streaming(
      (req, _) async => http.StreamedResponse(
        Stream.fromFuture(
          Future(() {
            read = true;
            return [1, 2, 3];
          }),
        ),
        200,
        headers: {'content-type': 'video/mp4'},
      ),
    );
    final text = await fetchPage(
      'https://example.com/v.mp4',
      httpClient: client,
      lookup: public,
    );
    expect(text, contains('is a file'));
    expect(read, isFalse);
  });
}
