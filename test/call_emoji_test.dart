import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/voice/call_emoji.dart';

void main() {
  test('the first emoji in the answer, as the web reads it', () {
    expect(firstEmoji('"😀"'), '😀');
    expect(firstEmoji('Sure: ☀️ and 🌧'), '☀');
    expect(firstEmoji('no emoji here'), isNull);
    expect(firstEmoji(null), isNull);
    expect(emojiInCallOn({'showEmojiInCall': true}), isTrue);
    expect(emojiInCallOn({}), isFalse);
  });
}
