import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/channels/channels_api.dart';
import 'package:nexus_assistant/features/channels/encrypted_chat.dart';

void main() {
  const on = {'enable_channels': true, 'enable_encrypted_channels': true};

  test('who may use encrypted chats, as the web decides', () {
    expect(canUseEncryption({'role': 'admin'}, on), isTrue);
    expect(
      canUseEncryption({'role': 'admin'}, {'enable_channels': true}),
      isFalse,
    );
    expect(canUseEncryption({'role': 'user'}, on), isFalse);
    expect(
      canUseEncryption({
        'role': 'user',
        'permissions': {
          'features': {'channels': true, 'encrypted_channels': true},
        },
      }, on),
      isTrue,
    );
    expect(canUseEncryption({'role': 'pending'}, on), isFalse);
    expect(canUseEncryption(null, null), isFalse);
  });

  test('only in direct messages and private groups', () {
    Channel c(String type, {bool private = false}) => Channel.fromJson({
      'id': 'c',
      'name': 'n',
      'type': type,
      'is_private': private,
    });
    expect(encryptionFits(c('dm')), isTrue);
    expect(encryptionFits(c('group', private: true)), isTrue);
    expect(encryptionFits(c('group')), isFalse);
    expect(encryptionFits(c('')), isFalse);
  });
}
