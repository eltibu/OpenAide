// Runs against a real Open WebUI server as an admin; see
// server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/settings/settings_api.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('profile extras, status and API keys', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final api = SettingsApi(client);
    final me = await api.me();

    await api.updateProfile(
      name: '${me['name']}',
      imageUrl: '${me['profile_image_url']}',
      gender: 'female',
      dateOfBirth: '1990-04-02',
    );
    var now = await api.me();
    expect(now['gender'], 'female');
    expect(now['date_of_birth'], '1990-04-02');
    await api.updateProfile(
      name: '${me['name']}',
      imageUrl: '${me['profile_image_url']}',
    );
    now = await api.me();
    expect(now['gender'], isNull);

    await api.setStatus(emoji: '🏖️', message: 'Away');
    now = await api.me();
    expect(now['status_message'], 'Away');
    await api.setStatus();
    expect((await api.me())['status_message'], isEmpty);

    // API keys need the admin switch.
    const cfg = '/api/v1/auths/admin/config';
    final admin = (await client.send('GET', cfg) as Map)
        .cast<String, dynamic>();
    await client.send('POST', cfg, body: {...admin, 'ENABLE_API_KEYS': true});
    try {
      final key = await api.createApiKey();
      expect(key, startsWith('sk-'));
      expect(await api.apiKey(), key);
      await api.deleteApiKey();
      expect(await api.apiKey(), isNull);
    } finally {
      await client.send('POST', cfg, body: admin);
    }
  }, skip: skip);
}
