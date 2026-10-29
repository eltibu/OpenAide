import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_assistant/core/net/local_network.dart';
import 'package:nexus_assistant/features/settings/terminal_connections.dart';

void main() {
  final reached = <Uri>[];
  final inner = MockClient((req) async {
    reached.add(req.url);
    return http.Response('ok', 200);
  });
  setUp(reached.clear);

  test('terminals and tool servers: https or this phone only', () async {
    final client = EncryptedOnlyClient(inner);
    for (final url in [
      'http://pc:8000/files/cwd',
      'http://192.168.1.20:8000/x',
      'http://example.com/x',
    ]) {
      await expectLater(
        client.get(Uri.parse(url)),
        throwsA(isA<UnencryptedAddress>()),
      );
    }
    expect(reached, isEmpty);
    await client.get(Uri.parse('https://pc.example.com/x'));
    await client.get(Uri.parse('http://127.0.0.1:8000/x'));
    await client.get(Uri.parse('http://localhost:8000/x'));
    expect(reached, hasLength(3));
  });

  test('your own server: home network ok, never the internet', () async {
    final client = EncryptedOnlyClient(inner, true);
    await client.get(Uri.parse('http://192.168.1.209/chat/api/config'));
    await expectLater(
      client.get(Uri.parse('http://chat.example.com/api/config')),
      throwsA(isA<UnencryptedAddress>()),
    );
    expect(reached, hasLength(1));
  });

  test('checking a terminal over plain http asks for https', () async {
    expect(await checkTerminal('http://nas:8000', 'k'), contains('https'));
  });
}
