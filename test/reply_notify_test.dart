import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/reply_notify.dart';

void main() {
  test('notification text is the reply, plain and short', () {
    expect(
      notificationText('**Hello** there\n\n- one\n- two'),
      'Hello there one two',
    );
    expect(notificationText('x' * 400).length, 301);
  });
}
