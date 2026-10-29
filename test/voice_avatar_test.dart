import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/voice/voice_avatar.dart';

/// A binary glTF with [json] and an empty binary chunk.
Uint8List glb(Map json) {
  var text = utf8.encode(jsonEncode(json));
  while (text.length % 4 != 0) {
    text = Uint8List.fromList([...text, 0x20]);
  }
  final total = 12 + 8 + text.length + 8 + 4;
  final out = ByteData(total);
  out
    ..setUint32(0, 0x46546c67, Endian.little)
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, total, Endian.little)
    ..setUint32(12, text.length, Endian.little)
    ..setUint32(16, 0x4e4f534a, Endian.little);
  final bytes = out.buffer.asUint8List()..setRange(20, 20 + text.length, text);
  final bin = ByteData.sublistView(bytes, 20 + text.length);
  bin
    ..setUint32(0, 4, Endian.little)
    ..setUint32(4, 0x004e4942, Endian.little);
  return bytes;
}

Map rig({List<String> skip = const []}) => {
  'asset': {'version': '2.0'},
  'nodes': [
    for (var i = 0; i < 8; i++) {'name': 'n$i'},
  ],
  'buffers': [
    {'byteLength': 4},
  ],
  'extensions': {
    'VRMC_vrm': {
      'humanoid': {
        'humanBones': {
          for (final (i, b) in const [
            'hips',
            'spine',
            'head',
            'leftUpperArm',
            'rightUpperArm',
            'leftLowerArm',
            'rightLowerArm',
          ].indexed)
            if (!skip.contains(b)) b: {'node': i},
        },
      },
    },
  },
};

void main() {
  test('a rigged VRM passes; others say why not', () {
    expect(checkVrm(glb(rig())), isNull);
    expect(checkVrm(glb(rig(skip: ['head']))), contains('head bone'));
    expect(
      checkVrm(
        glb({
          'asset': {'version': '2.0'},
        }),
      ),
      contains('humanoid rig'),
    );
    expect(
      checkVrm(
        Uint8List.fromList(
          utf8.encode('not a model at all, just some plain text'),
        ),
      ),
      'Upload a binary VRM file.',
    );
    final external = rig()
      ..['buffers'] = [
        {'uri': 'model.bin', 'byteLength': 4},
      ];
    expect(checkVrm(glb(external)), contains('Embed all'));
  });

  test('VRM 0.x lists its bones', () {
    final old = rig();
    old['extensions'] = {
      'VRM': {
        'humanoid': {
          'humanBones': [
            for (final (i, b) in const [
              'hips',
              'spine',
              'head',
              'leftUpperArm',
              'rightUpperArm',
              'leftLowerArm',
              'rightLowerArm',
            ].indexed)
              {'bone': b, 'node': i},
          ],
        },
      },
    };
    expect(checkVrm(glb(old)), isNull);
  });

  test('the setting reads and writes as the web keeps it', () {
    final meta = {
      'voice_avatar': {
        'file_id': 'f1',
        'states': {
          'idle': {'file_id': 'a1'},
          'speaking': {'file_id': 'a2'},
        },
        'gestures': [
          {'name': 'wave', 'description': 'Greeting', 'file_id': 'g1'},
        ],
      },
    };
    final c = VoiceAvatarConfig.fromMeta(meta)!;
    expect(c.fileId, 'f1');
    expect(c.states, {'idle': 'a1', 'speaking': 'a2'});
    expect(c.gestures.single.name, 'wave');
    expect(c.toJson(), meta['voice_avatar']);
    expect(VoiceAvatarConfig.fromMeta({'voice_avatar': null}), isNull);
    expect(VoiceAvatarConfig(fileId: 'x').toJson(), {'file_id': 'x'});
  });

  test('no avatar on a call: gestures are unavailable', () async {
    expect(await AvatarHandle().gesture('wave'), 'unavailable');
  });
}
