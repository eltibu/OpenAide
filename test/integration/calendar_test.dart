// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/calendar/calendar_api.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('creates, repeats, edits and deletes events', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final api = CalendarApi(client);

    final calendars = await api.calendars();
    final mine = calendars.firstWhere((c) => c.isDefault);
    expect(calendars.any((c) => c.id == scheduledTasksId), isTrue);

    final start = DateTime(2031, 3, 3, 9, 30); // a Monday
    await api.createEvent({
      'calendar_id': mine.id,
      'title': 'nexus standup',
      'start_at': toNs(start),
      'end_at': toNs(start.add(const Duration(minutes: 15))),
      'all_day': false,
      'rrule': repeatRules['weekdays'],
      'meta': {'alert_minutes': 5},
    });

    var week = await api.events(DateTime(2031, 3, 2), DateTime(2031, 3, 9));
    var mineNow = week.where((e) => e.title == 'nexus standup').toList();
    expect(mineNow.length, 5);
    expect(mineNow.every((e) => e.isInstance), isTrue);
    expect(mineNow[1].start, DateTime(2031, 3, 4, 9, 30));
    expect(mineNow[1].isOn(DateTime(2031, 3, 4)), isTrue);
    expect(mineNow[1].isOn(DateTime(2031, 3, 5)), isFalse);

    final stored = await api.event(mineNow[2].id);
    expect(stored.start, start);
    expect(stored.alertMinutes, 5);
    expect(repeatOf(stored.rrule), 'weekdays');

    await api.updateEvent(stored.id, {'title': 'nexus sync', 'rrule': null});
    week = await api.events(DateTime(2031, 3, 2), DateTime(2031, 3, 9));
    mineNow = week.where((e) => e.title == 'nexus sync').toList();
    expect(mineNow.length, 1);

    await api.deleteEvent(stored.id);
    week = await api.events(DateTime(2031, 3, 2), DateTime(2031, 3, 9));
    expect(week.where((e) => e.id == stored.id), isEmpty);
  }, skip: skip);
}
