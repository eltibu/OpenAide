import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/offline/offline_cache.dart';

void main() {
  tearDown(() {
    OpenWebUiClient.offline = null;
    offlineNotice.value = false;
  });

  test('what can be kept: chats, folders, notes, models and settings', () {
    expect(offlineCacheable('/api/v1/chats/'), isTrue);
    expect(offlineCacheable('/api/v1/chats/pinned'), isTrue);
    expect(
      offlineCacheable('/api/v1/chats/0f8c1e2a-3b4c-4d5e-8f90-123456789abc'),
      isTrue,
    );
    expect(offlineCacheable('/api/v1/chats/folder/abc/list'), isTrue);
    expect(offlineCacheable('/api/v1/folders/'), isTrue);
    expect(offlineCacheable('/api/models'), isTrue);
    expect(offlineCacheable('/api/v1/files/'), isFalse);
    expect(offlineCacheable('/api/chat/completions'), isFalse);
    expect(
      offlineKey('/api/v1/chats/', {'page': '2'}),
      '/api/v1/chats/?page=2',
    );
  });

  test('with no connection, the last read comes back and says so', () async {
    final store = MemoryOfflineStore();
    OpenWebUiClient.offline = store;
    var up = true;
    final client = OpenWebUiClient(
      baseUrl: 'https://chat.example',
      token: 't',
      httpClient: MockClient((req) async {
        if (!up) throw const SocketException('Connection refused');
        return http.Response(
          jsonEncode([
            {'id': 'c1', 'title': 'Groceries', 'updated_at': 1},
          ]),
          200,
        );
      }),
    );
    final live = await client.chats();
    expect(live.single.title, 'Groceries');
    expect(offlineNotice.value, isFalse);
    expect(store.values, hasLength(1));

    up = false;
    final saved = await client.chats();
    expect(saved.single.title, 'Groceries');
    expect(offlineNotice.value, isTrue);

    // Never seen before: the error, as without saved copies.
    await expectLater(
      client.chats(page: 2),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 0)),
    );

    up = true;
    await client.chats();
    expect(offlineNotice.value, isFalse);
  });

  test('server errors are not hidden by saved copies', () async {
    final store = MemoryOfflineStore();
    OpenWebUiClient.offline = store;
    await store.put('https://chat.example /api/v1/folders/', '[]');
    final client = OpenWebUiClient(
      baseUrl: 'https://chat.example',
      httpClient: MockClient(
        (_) async => http.Response('{"detail":"no"}', 401),
      ),
    );
    await expectLater(
      client.send('GET', '/api/v1/folders/'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
    );
  });

  test('saved copies on the phone, the oldest going first', () async {
    final dir = await Directory.systemTemp.createTemp('offline');
    final store = FileOfflineStore(dir, keep: 5);
    for (var i = 0; i < 20; i++) {
      await store.put('k$i', '$i');
    }
    expect(await store.get('k19'), '19');
    expect(dir.listSync().length, lessThanOrEqualTo(5));
    await store.clear();
    expect(await store.get('k19'), isNull);
  });
}
