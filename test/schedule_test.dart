import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/automations/automations_api.dart';

void main() {
  test('reads and writes the web UI schedules', () {
    for (final rule in [
      'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0',
      'RRULE:FREQ=WEEKLY;BYDAY=MO,WE;BYHOUR=7;BYMINUTE=30',
      'RRULE:FREQ=MONTHLY;BYMONTHDAY=15;BYHOUR=18;BYMINUTE=5',
      'RRULE:FREQ=HOURLY;INTERVAL=3;BYMINUTE=10',
      'DTSTART:20311224T081500\nRRULE:FREQ=DAILY;COUNT=1',
    ]) {
      expect(Schedule.parse(rule).build(), rule);
    }
    final once = Schedule.parse(
      'DTSTART:20311224T081500\nRRULE:FREQ=DAILY;COUNT=1',
    );
    expect(once.frequency, 'ONCE');
    expect(once.once, DateTime(2031, 12, 24, 8, 15));
    final custom = Schedule.parse('RRULE:FREQ=DAILY;UNTIL=20320101T000000Z');
    expect(custom.frequency, 'CUSTOM');
    expect(custom.build(), 'RRULE:FREQ=DAILY;UNTIL=20320101T000000Z');
    String t(int h, int m) => '$h:${'$m'.padLeft(2, '0')}';
    expect(
      Schedule.parse('RRULE:FREQ=WEEKLY;BYDAY=MO,WE;BYHOUR=7;BYMINUTE=30')
          .describe(t),
      'Mo, We at 7:30',
    );
  });
}
