import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/emoji.dart';

void main() {
  test('shortcodes match by prefix first', () {
    final found = matchEmoji('heart');
    expect(found.first, ('heart', '❤️'));
    expect(found.map((e) => e.$1), contains('heart_eyes'));
    expect(matchEmoji('thumbsup').single.$2, '👍');
    expect(matchEmoji('zzzzqq'), isEmpty);
  });

  test('every shortcode is unique', () {
    final names = emojiShortcodes.map((e) => e.$1).toList();
    expect(names.toSet(), hasLength(names.length));
  });
}
