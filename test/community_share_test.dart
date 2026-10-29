import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/server/community_share.dart';

void main() {
  test('the hand-over answers "loaded" with the item, quoted safely', () {
    const item = '{"name":"it\'s </script> \\"x\\""}';
    final js = communityHandOver(item);
    expect(js, contains("m === 'loaded'"));
    expect(js, contains('window.postMessage(${jsonEncode(item)}'));
    expect(js, contains("Object.defineProperty(window, 'opener'"));
  });

  test('a chat goes with only the models it used', () {
    final out = jsonDecode(
      chatCommunityPayload(
        {
          'title': 'Hi',
          'models': ['a'],
        },
        [
          {'id': 'a', 'name': 'A'},
          {'id': 'b', 'name': 'B'},
        ],
      ),
    );
    expect(out['chat']['title'], 'Hi');
    expect(out['models'], [
      {'id': 'a', 'name': 'A'},
    ]);
  });

  test('sharing shows only when the server allows it', () {
    expect(communitySharingOn(null), isFalse);
    expect(
      communitySharingOn({
        'features': {'enable_community_sharing': false},
      }),
      isFalse,
    );
    expect(
      communitySharingOn({
        'features': {'enable_community_sharing': true},
      }),
      isTrue,
    );
  });
}
