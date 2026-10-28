import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/phone/phone_actions.dart';

void main() {
  test('timers', () {
    int? secs(String s) => switch (parsePhoneAction(s)) {
      TimerAction(:final seconds) => seconds,
      _ => null,
    };
    expect(secs('Set a timer for 10 minutes'), 600);
    expect(secs('timer 90 seconds'), 90);
    expect(secs('Hey Nexus, set a 5 minute timer.'), 300);
    expect(secs('set a timer for an hour and a half'), 5400);
    expect(secs('timer for 1h 30m'), 5400);
    expect(secs('timer for half an hour'), 1800);
    expect(secs('timer for two minutes please'), 120);
    expect(durationWords(5400), '1 hour 30 minutes');
  });

  test('alarms', () {
    (int, int)? at(String s) => switch (parsePhoneAction(s)) {
      AlarmAction(:final hour, :final minute) => (hour, minute),
      _ => null,
    };
    expect(at('Wake me up at 6:30'), (6, 30));
    expect(at('set an alarm for 7 pm'), (19, 0));
    expect(at('alarm at 12 am'), (0, 0));
    expect(at('set alarm for 7:15 a.m. tomorrow'), (7, 15));
    expect(at('alarm for noon'), (12, 0));
    expect(clockWords(19, 5), '7:05 PM');
  });

  test('calls, texts, apps, directions, flashlight', () {
    expect((parsePhoneAction('Call Mom') as CallAction).who, 'Mom');
    expect(
      (parsePhoneAction('call 555-123-4567') as CallAction).who,
      '555-123-4567',
    );
    expect(parsePhoneAction('call me Joel'), isNull);
    final text =
        parsePhoneAction('Text Sam saying Running late!') as TextAction;
    expect((text.who, text.body), ('Sam', 'Running late'));
    final send = parsePhoneAction(
      'send a message to Rosanna that dinner is ready',
    ) as TextAction;
    expect((send.who, send.body), ('Rosanna', 'dinner is ready'));
    expect((parsePhoneAction('Open Spotify') as OpenAppAction).name, 'Spotify');
    expect(
      (parsePhoneAction('open the camera app') as OpenAppAction).name,
      'camera',
    );
    expect(
      (parsePhoneAction('directions to the Airport') as NavigateAction).place,
      'the Airport',
    );
    expect(
      (parsePhoneAction('turn on the flashlight') as TorchAction).on,
      true,
    );
    expect((parsePhoneAction('turn the torch off') as TorchAction).on, false);
  });

  test('ordinary messages stay messages', () {
    for (final s in [
      'What time is it in Tokyo?',
      'Write a poem about timers',
      'How do I set an alarm in Python?',
      'Summarize this call transcript',
      '',
    ]) {
      expect(parsePhoneAction(s), isNull, reason: s);
    }
  });
}
