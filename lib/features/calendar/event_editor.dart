import 'package:flutter/material.dart';

import 'calendar_api.dart';

/// Creating or changing an event, with the same fields as the web UI.
/// Pops true when something was saved or deleted.
class EventEditor extends StatefulWidget {
  const EventEditor({
    super.key,
    required this.api,
    required this.calendars,
    required this.start,
    this.event,
  });

  final CalendarApi api;
  final List<Calendar> calendars;
  final CalendarEvent? event;

  /// Where a new event starts.
  final DateTime start;

  @override
  State<EventEditor> createState() => _EventEditorState();
}

const _reminders = <int, String>{
  -1: 'None',
  0: 'At time of event',
  5: '5 minutes before',
  10: '10 minutes before',
  15: '15 minutes before',
  30: '30 minutes before',
  60: '1 hour before',
};

const _repeats = <String, String>{
  '': 'Does not repeat',
  'daily': 'Daily',
  'weekdays': 'Monday to Friday',
  'weekly': 'Weekly',
  'monthly': 'Monthly',
  'yearly': 'Yearly',
};

class _EventEditorState extends State<EventEditor> {
  late final CalendarEvent? _e = widget.event;
  late final _title = TextEditingController(text: _e?.title ?? '');
  late final _location = TextEditingController(text: _e?.location ?? '');
  late final _description = TextEditingController(text: _e?.description ?? '');
  late String _calendarId = _initialCalendar();
  late DateTime _start = _e?.start ?? widget.start;
  late DateTime _end =
      _e?.end ?? (_e?.start ?? widget.start).add(const Duration(hours: 1));
  late bool _allDay = _e?.allDay ?? false;
  late int _alert = _reminders.containsKey(_e?.alertMinutes)
      ? _e!.alertMinutes
      : 10;
  late String _repeat = repeatOf(_e?.rrule);
  bool _busy = false;

  String _initialCalendar() {
    final ids = widget.calendars.map((c) => c.id);
    if (_e != null && ids.contains(_e.calendarId)) return _e.calendarId;
    return widget.calendars
        .firstWhere((c) => c.isDefault, orElse: () => widget.calendars.first)
        .id;
  }

  Future<void> _pickDate(bool start) async {
    final d = await showDatePicker(
      context: context,
      initialDate: start ? _start : _end,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() {
      if (start) {
        final length = _end.difference(_start);
        _start = DateTime(d.year, d.month, d.day, _start.hour, _start.minute);
        _end = _start.add(length);
      } else {
        _end = DateTime(d.year, d.month, d.day, _end.hour, _end.minute);
      }
    });
  }

  Future<void> _pickTime(bool start) async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(start ? _start : _end),
    );
    if (t == null) return;
    setState(() {
      if (start) {
        final length = _end.difference(_start);
        _start = DateTime(
          _start.year,
          _start.month,
          _start.day,
          t.hour,
          t.minute,
        );
        _end = _start.add(length);
      } else {
        _end = DateTime(_end.year, _end.month, _end.day, t.hour, t.minute);
        // Ending earlier than it starts means the next day, as on the web.
        if (_end.isBefore(_start)) _end = _end.add(const Duration(days: 1));
      }
    });
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      _say('Add a title');
      return;
    }
    final start = _allDay
        ? DateTime(_start.year, _start.month, _start.day)
        : _start;
    var end = _allDay
        ? DateTime(_end.year, _end.month, _end.day, 23, 59)
        : _end;
    if (end.isBefore(start)) end = start;
    final rrule = _repeat == 'custom' ? _e?.rrule : repeatRules[_repeat];
    final form = <String, dynamic>{
      'calendar_id': _calendarId,
      'title': title,
      'description': _description.text.trim().isEmpty
          ? null
          : _description.text.trim(),
      'start_at': toNs(start),
      'end_at': toNs(end),
      'all_day': _allDay,
      'rrule': rrule,
      'location': _location.text.trim().isEmpty ? null : _location.text.trim(),
      'meta': {...?_e?.meta, 'alert_minutes': _alert},
    };
    setState(() => _busy = true);
    try {
      if (_e == null) {
        form.removeWhere((_, v) => v == null);
        await widget.api.createEvent(form);
      } else {
        await widget.api.updateEvent(_e.id, form);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _say('$e');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete this event?'),
        content: Text(
          _e?.rrule != null
              ? 'Every time it repeats is deleted. This can\'t be undone.'
              : 'This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await widget.api.deleteEvent(_e!.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _say('$e');
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    String date(DateTime d) => l10n.formatMediumDate(d);
    String time(DateTime d) => l10n.formatTimeOfDay(TimeOfDay.fromDateTime(d));
    return Scaffold(
      appBar: AppBar(
        title: Text(_e == null ? 'New event' : 'Edit event'),
        actions: [
          if (_e != null)
            IconButton(
              tooltip: 'Delete',
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_e == null ? 'Create' : 'Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _title,
              autofocus: _e == null,
              minLines: 1,
              maxLines: 3,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              style: const TextStyle(fontSize: 20),
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Event title',
                border: InputBorder.none,
              ),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.layers_outlined),
            title: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _calendarId,
                isExpanded: true,
                onChanged: (v) => setState(() => _calendarId = v!),
                items: [
                  for (final c in widget.calendars)
                    DropdownMenuItem(
                      value: c.id,
                      child: Row(
                        children: [
                          CircleAvatar(radius: 6, backgroundColor: c.color),
                          const SizedBox(width: 10),
                          Text(c.name),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.schedule),
            title: const Text('All day'),
            value: _allDay,
            onChanged: (v) => setState(() => _allDay = v),
          ),
          _WhenRow(
            label: 'Starts',
            date: date(_start),
            time: _allDay ? null : time(_start),
            onDate: () => _pickDate(true),
            onTime: () => _pickTime(true),
          ),
          _WhenRow(
            label: 'Ends',
            date: date(_end),
            time: _allDay ? null : time(_end),
            onDate: () => _pickDate(false),
            onTime: () => _pickTime(false),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.repeat),
            title: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _repeat,
                isExpanded: true,
                onChanged: (v) => setState(() => _repeat = v!),
                items: [
                  for (final r in _repeats.entries)
                    DropdownMenuItem(value: r.key, child: Text(r.value)),
                  if (_repeat == 'custom' || repeatOf(_e?.rrule) == 'custom')
                    const DropdownMenuItem(
                      value: 'custom',
                      child: Text('Custom (as set on the server)'),
                    ),
                ],
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_none),
            title: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _alert,
                isExpanded: true,
                onChanged: (v) => setState(() => _alert = v!),
                items: [
                  for (final r in _reminders.entries)
                    DropdownMenuItem(value: r.key, child: Text(r.value)),
                ],
              ),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.place_outlined),
            title: TextField(
              controller: _location,
              decoration: const InputDecoration(
                hintText: 'Add location',
                border: InputBorder.none,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.notes),
            title: TextField(
              controller: _description,
              minLines: 3,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Add description',
                border: InputBorder.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WhenRow extends StatelessWidget {
  const _WhenRow({
    required this.label,
    required this.date,
    required this.time,
    required this.onDate,
    required this.onTime,
  });

  final String label;
  final String date;
  final String? time;
  final VoidCallback onDate;
  final VoidCallback onTime;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 72, right: 12),
    child: Row(
      children: [
        SizedBox(width: 56, child: Text(label)),
        TextButton(onPressed: onDate, child: Text(date)),
        const Spacer(),
        if (time != null) TextButton(onPressed: onTime, child: Text(time!)),
      ],
    ),
  );
}
