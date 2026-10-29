// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/settings/language_settings.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('the server\'s model is asked to translate the app', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final models = (await client.send('GET', '/api/models')) as Map;
    final model = '${((models['data'] as List).first as Map)['id']}';
    // Whatever the model says, only phrases that were asked come back.
    final got = await translateWithServer(client, model, 'Español', [
      'Add people',
    ]);
    expect(got.keys.toSet().difference({'Add people'}), isEmpty);
  }, skip: skip);
}
