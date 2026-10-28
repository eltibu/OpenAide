// Runs against a real Open WebUI server; see server_sync_test.dart. Set
// AVATAR_VRM (and AVATAR_VRMA) to a sample avatar and animation to run it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/voice/voice_avatar.dart';
import 'package:nexus_assistant/features/workspace/models_api.dart';

void main() {
  final env = Platform.environment;
  final url = env['OWUI_URL'];
  final vrm = env['AVATAR_VRM'];
  final vrma = env['AVATAR_VRMA'];
  final skip = url == null || vrm == null || vrma == null
      ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD, AVATAR_VRM, AVATAR_VRMA'
      : null;

  test('a model keeps its voice avatar, as the server checks it', () async {
    HttpOverrides.global = null;
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(env['OWUI_EMAIL']!, env['OWUI_PASSWORD']!);
    final avatar = await client.uploadFile(
      File(vrm!).readAsBytesSync(),
      'avatar.vrm',
      contentType: 'application/octet-stream',
      process: false,
    );
    final wave = await client.uploadFile(
      File(vrma!).readAsBytesSync(),
      'wave.vrma',
      contentType: 'application/octet-stream',
      process: false,
    );
    final config = VoiceAvatarConfig(
      fileId: avatar['id'] as String,
      states: {'idle': wave['id'] as String},
      gestures: [
        (name: 'wave', description: 'Greeting', fileId: wave['id'] as String),
      ],
    );
    final api = ModelsApi(client);
    final base =
        (((await client.send('GET', '/api/models')) as Map)['data'] as List)
            .first['id'];
    await api.save({
      'id': 'nexus-avatar-model',
      'name': 'Nexus avatar',
      'base_model_id': base,
      'meta': {'voice_avatar': config.toJson()},
      'params': {},
    }, create: true);
    try {
      final m = await api.get('nexus-avatar-model');
      final back = VoiceAvatarConfig.fromMeta(m.meta)!;
      expect(back.fileId, config.fileId);
      expect(back.states['idle'], wave['id']);
      expect(back.gestures.single.name, 'wave');

      // The avatar file itself as an animation is refused.
      await expectLater(
        api.save({
          ...m.json,
          'meta': {
            ...m.meta,
            'voice_avatar': config
                .copyWith(states: {'idle': config.fileId})
                .toJson(),
          },
        }, create: false),
        throwsA(isA<ApiException>()),
      );
    } finally {
      await api.delete('nexus-avatar-model');
    }
  }, skip: skip);
}
