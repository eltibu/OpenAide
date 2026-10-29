// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/admin/admin_api.dart';
import 'package:nexus_assistant/features/settings/settings_api.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;
  late OpenWebUiClient client;

  // One sign-in for the file: the server limits how often one can sign in.
  setUpAll(() async {
    if (url == null) return;
    client = OpenWebUiClient(baseUrl: url);
    await client.signIn(email!, password!);
  });

  test('settings change only what they touch', () async {
    final api = SettingsApi(client);
    final before = await api.ui();
    await api.patchUi({
      'system': 'Answer like a pirate, {{USER_NAME}}.',
      'params': {'temperature': 0.3, 'max_tokens': 99},
      'autoTags': false,
      'webSearch': 'always',
    });
    var ui = await api.ui();
    expect(ui['system'], 'Answer like a pirate, {{USER_NAME}}.');
    expect(ui['params'], {'temperature': 0.3, 'max_tokens': 99});
    expect(ui['autoTags'], isFalse);
    // Settings the app didn't send are kept.
    for (final k in before.keys) {
      if (!{'system', 'params', 'autoTags', 'webSearch'}.contains(k)) {
        expect(ui[k], before[k], reason: k);
      }
    }
    // Null puts a setting back to its default.
    await api.patchUi({
      'system': before['system'],
      'params': before['params'] ?? <String, dynamic>{},
      'autoTags': before['autoTags'],
      'webSearch': before['webSearch'],
    });
    ui = await api.ui();
    expect(ui.containsKey('webSearch'), before.containsKey('webSearch'));
    expect(ui['system'], before['system']);
  }, skip: skip);

  test('profile', () async {
    final api = SettingsApi(client);
    final me = await api.me();
    final image = '${me['profile_image_url'] ?? ''}';
    await api.updateProfile(name: 'Nexus Tester', imageUrl: image, bio: 'hi');
    expect((await api.me())['name'], 'Nexus Tester');
    expect((await api.me())['bio'], 'hi');
    await api.updateProfile(
      name: '${me['name']}',
      imageUrl: image,
      bio: me['bio'] as String?,
    );
    expect((await api.me())['name'], me['name']);
  }, skip: skip);

  test('memories', () async {
    final api = SettingsApi(client);
    await api.addMemory('Nexus test likes mangoes');
    var m = (await api.memories()).firstWhere(
      (m) => m.content == 'Nexus test likes mangoes',
    );
    await api.updateMemory(m.id, 'Nexus test likes papayas');
    m = (await api.memories()).firstWhere((x) => x.id == m.id);
    expect(m.content, 'Nexus test likes papayas');
    await api.deleteMemory(m.id);
    expect((await api.memories()).where((x) => x.id == m.id), isEmpty);
  }, skip: skip);

  test('archived chats', () async {
    final api = SettingsApi(client);
    expect(await api.archived(), isA<List<dynamic>>());
  }, skip: skip);

  test('admin users', () async {
    final api = AdminApi(client);
    const mail = 'nexus-admin-test@t.io';
    for (final u in await api.users(query: 'nexus-admin-test')) {
      await api.deleteUser(u.id);
    }
    await api.addUser(
      name: 'Nexus Temp',
      email: mail,
      password: 'pw123456',
      role: 'pending',
    );
    var u = (await api.users(query: 'nexus-admin-test')).single;
    expect(u.role, 'pending');
    await api.updateUser(u.id, role: 'user', name: 'Nexus Temp 2');
    u = (await api.users(query: 'nexus-admin-test')).single;
    expect(u.role, 'user');
    expect(u.name, 'Nexus Temp 2');
    expect(u.email, mail);
    await api.deleteUser(u.id);
    expect(await api.users(query: 'nexus-admin-test'), isEmpty);
    expect((await api.users()).length, greaterThan(0));
  }, skip: skip);

  test('admin settings save back unchanged, and switch', () async {
    final api = AdminApi(client);
    final config = await api.config();
    final saved = await api.saveConfig({
      ...config,
      'ENABLE_MESSAGE_RATING': !(config['ENABLE_MESSAGE_RATING'] == true),
    });
    expect(
      saved['ENABLE_MESSAGE_RATING'],
      config['ENABLE_MESSAGE_RATING'] != true,
    );
    final back = await api.saveConfig(config);
    for (final k in config.keys) {
      expect(back[k], config[k], reason: k);
    }
    expect(await api.functions(), isA<List<ServerFunction>>());
  }, skip: skip);

  test('playground streams a reply', () async {
    final model = (await client.models()).first.id;
    final text = await client
        .streamCompletion(
          model: model,
          messages: [
            {'role': 'system', 'content': 'Be brief.'},
            {'role': 'user', 'content': 'Say hi'},
          ],
          extraParams: {'temperature': 0.5},
        )
        .join();
    expect(text, isNotEmpty);
  }, skip: skip);
}
