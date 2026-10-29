import 'package:flutter/material.dart';

import '../../core/api/openwebui_client.dart';

/// The virtual calendar the server adds for automation runs.
const scheduledTasksId = '__scheduled_tasks__';

/// Repeat choices, as the web UI offers them.
const repeatRules = <String, String>{
  'daily': 'FREQ=DAILY',
  'weekdays': 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
  'weekly': 'FREQ=WEEKLY',
  'monthly': 'FREQ=MONTHLY',
  'yearly': 'FREQ=YEARLY',
};

/// Which repeat choice an RRULE is: '' for none, 'custom' for one the app
/// can't edit (kept as it is).
String repeatOf(String? rrule) {
  if (rrule == null || rrule.trim().isEmpty) return '';
  final n = rrule.toUpperCase().replaceAll(RegExp(r'\s'), '');
  for (final e in repeatRules.entries) {
    if (e.value == n) return e.key;
  }
  return 'custom';
}

// The server keeps times in nanoseconds.
DateTime fromNs(num ns) =>
    DateTime.fromMicrosecondsSinceEpoch((ns / 1000).round());
int toNs(DateTime t) => t.microsecondsSinceEpoch * 1000;

/// '#rrggbb' to a colour.
Color? parseColor(String? hex) {
  if (hex == null) return null;
  final h = hex.replaceFirst('#', '');
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

String colorHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

class Calendar {
  const Calendar({
    required this.id,
    required this.name,
    required this.color,
    required this.isDefault,
    required this.isSystem,
    required this.userId,
  });

  factory Calendar.fromJson(Map j) => Calendar(
    id: '${j['id']}',
    name: '${j['name'] ?? ''}',
    color: parseColor(j['color'] as String?),
    isDefault: j['is_default'] == true,
    isSystem: j['is_system'] == true,
    userId: '${j['user_id'] ?? ''}',
  );

  final String id;
  final String name;
  final Color? color;
  final bool isDefault;
  final bool isSystem;
  final String userId;
}

class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.calendarId,
    required this.title,
    required this.start,
    this.end,
    this.allDay = false,
    this.description,
    this.location,
    this.rrule,
    this.color,
    this.meta = const {},
    this.isInstance = false,
  });

  factory CalendarEvent.fromJson(Map j) => CalendarEvent(
    id: '${j['id']}',
    calendarId: '${j['calendar_id']}',
    title: '${j['title'] ?? ''}',
    start: fromNs(j['start_at'] as num),
    end: j['end_at'] is num ? fromNs(j['end_at'] as num) : null,
    allDay: j['all_day'] == true,
    description: j['description'] as String?,
    location: j['location'] as String?,
    rrule: j['rrule'] as String?,
    color: parseColor(j['color'] as String?),
    meta: (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
    isInstance: j['instance_id'] != null,
  );

  final String id;
  final String calendarId;
  final String title;
  final DateTime start;
  final DateTime? end;
  final bool allDay;
  final String? description;
  final String? location;
  final String? rrule;
  final Color? color;
  final Map<String, dynamic> meta;

  /// One occurrence of a repeating event; editing it edits the series.
  final bool isInstance;

  /// A scheduled task or one of its runs, made by an automation.
  String? get automationId => meta['automation_id'] as String?;
  String? get chatId => meta['chat_id'] as String?;
  String? get runStatus => meta['status'] as String?;
  int get alertMinutes => (meta['alert_minutes'] as num?)?.toInt() ?? 10;

  /// Whether it is on the given day (local time).
  bool isOn(DateTime day) {
    final from = DateTime(day.year, day.month, day.day);
    final to = from.add(const Duration(days: 1));
    final last = end ?? start;
    return start.isBefore(to) &&
        (last.isAfter(from) || !start.isBefore(from) || last == from);
  }
}

class CalendarApi {
  CalendarApi(this.client);
  final OpenWebUiClient client;

  static const _base = '/api/v1/calendars';

  Future<List<Calendar>> calendars() async {
    final res = await client.send('GET', '$_base/');
    return [
      for (final c in (res as List? ?? const []).whereType<Map>())
        Calendar.fromJson(c),
    ];
  }

  Future<List<CalendarEvent>> events(DateTime from, DateTime to) async {
    final res = await client.send(
      'GET',
      '$_base/events',
      query: {
        'start': from.toUtc().toIso8601String(),
        'end': to.toUtc().toIso8601String(),
      },
    );
    return [
      for (final e in (res as List? ?? const []).whereType<Map>())
        CalendarEvent.fromJson(e),
    ]..sort((a, b) => a.start.compareTo(b.start));
  }

  Future<CalendarEvent> event(String id) async => CalendarEvent.fromJson(
    await client.send('GET', '$_base/events/${Uri.encodeComponent(id)}') as Map,
  );

  Future<void> createEvent(Map<String, dynamic> form) =>
      client.send('POST', '$_base/events/create', body: form);

  Future<void> updateEvent(String id, Map<String, dynamic> form) => client.send(
    'POST',
    '$_base/events/${Uri.encodeComponent(id)}/update',
    body: form,
  );

  Future<void> deleteEvent(String id) =>
      client.send('DELETE', '$_base/events/${Uri.encodeComponent(id)}/delete');

  Future<void> createCalendar(String name, Color color) => client.send(
    'POST',
    '$_base/create',
    body: {'name': name, 'color': colorHex(color)},
  );

  Future<void> deleteCalendar(String id) =>
      client.send('DELETE', '$_base/${Uri.encodeComponent(id)}/delete');

  Future<void> makeDefault(String id) =>
      client.send('POST', '$_base/${Uri.encodeComponent(id)}/default');
}
