import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/chat/chat_screen.dart';

void main() {
  test('message times in seconds or milliseconds', () {
    final t = DateTime(2026, 10, 28, 15, 4);
    final s = t.millisecondsSinceEpoch ~/ 1000;
    expect(messageDate(s), t);
    expect(messageDate(t.millisecondsSinceEpoch), t);
  });

  test('a timer going off is a timer line, not your message', () {
    ChatMessage m(Map<String, dynamic> extra) => ChatMessage.fromJson({
      'id': '1',
      'role': 'user',
      'content': 'Check the oven',
      ...extra,
    });
    expect(
      isTimerMessage(m({
        'meta': {'internal': true, 'type': 'timer'},
      })),
      isTrue,
    );
    expect(isTimerMessage(m({})), isFalse);
    expect(
      isTimerMessage(m({
        'meta': {'type': 'timer'},
      })),
      isFalse,
    );
  });
}
