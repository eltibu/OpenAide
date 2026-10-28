// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/admin/apps_screen.dart';

const _publicKey = '''-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAgluucNSvYo6jExeqg8yNiHSQ71J9JB3p1sePrqkAt/k=
-----END PUBLIC KEY-----
''';

void main() {
  final url = Platform.environment['OWUI_URL'];

  test('slugs and states read as on the web', () {
    expect(appSlug('Com.Example_Bot'), 'com-example-bot');
    expect(appSlug('42'), 'app');
    expect(
      appState(ServerApp({'configured': false, 'is_active': false})),
      'Uninstalled',
    );
    expect(
      appState(
        ServerApp({
          'configured': true,
          'is_active': true,
          'connection_status': 'connecting',
        }),
      ),
      'Connecting',
    );
  });

  test('add, change, list and uninstall an app', () async {
    HttpOverrides.global = null;
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(
      Platform.environment['OWUI_EMAIL']!,
      Platform.environment['OWUI_PASSWORD']!,
    );
    final before = (await client.send(
      'GET',
      '/api/v1/auths/admin/config',
    ) as Map).cast<String, dynamic>();
    await client.send(
      'POST',
      '/api/v1/auths/admin/config',
      body: {...before, 'ENABLE_APPS': true},
    );
    addTearDown(
      () => client.send(
        'POST',
        '/api/v1/auths/admin/config',
        body: {...before, 'ENABLE_APPS': before['ENABLE_APPS'] ?? false},
      ),
    );
    final api = AppsApi(client);

    // Asking an address that isn't an app says why.
    await expectLater(
      api.preview('http://127.0.0.1:1/x', apiKey: 'k'),
      throwsA(isA<ApiException>()),
    );

    final slug = 'nexus-test-${DateTime.now().millisecondsSinceEpoch}';
    final app = await api.create(
      manifest: {
        'id': slug,
        'name': 'Nexus test app',
        'public_key': _publicKey,
        'requested_scopes': ['channels:read', 'channels:mentions:read'],
      },
      url: 'https://apps.example.com/$slug',
      apiKey: 'secret',
      slug: slug,
      scopes: ['channels:read'],
      grants: const [(type: 'user', id: '*', permission: 'read')],
    );
    expect(app.configured, isTrue);
    expect(app.active, isFalse);
    expect(app.grantedScopes, ['channels:read']);

    final full = await api.get(app.id);
    expect(full.raw['access_grants'], isNotEmpty);

    final changed = await api.update(
      app.id,
      name: 'Renamed app',
      scopes: ['channels:read', 'channels:mentions:read'],
      grants: const [],
    );
    expect(changed.name, 'Renamed app');
    expect(changed.grantedScopes, hasLength(2));
    expect((await api.get(app.id)).raw['access_grants'], isEmpty);
    expect((await api.list()).map((a) => a.id), contains(app.id));

    await api.uninstall(app.id);
    final gone = (await api.list()).firstWhere((a) => a.id == app.id);
    expect(appState(gone), 'Uninstalled');
  }, skip: url == null ? 'Set OWUI_URL' : null);
}
