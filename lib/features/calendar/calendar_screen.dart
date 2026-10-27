import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import '../server/server_page.dart';
import 'calendar_api.dart';
import 'event_editor.dart';

/// The server's calendar, native: a month at a glance and the chosen day's
/// events, with the same calendars, events and scheduled tasks as the web.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  late final CalendarApi _api = CalendarApi(ref.read(clientProvider));
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _day = _today();
  List<Calendar> _calendars = const [];
  List<CalendarEvent> _events = const [];
  final Set<String> _hidden = {};
  Object? _error;
  bool _loading = true;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  // Six weeks from the Sunday on or before the 1st, as the web shows.
  DateTime get _gridStart =>
      _month.subtract(Duration(days: _month.weekday % 7));

  @override
  void initState() {
    super.initState();
    _load(calendars: true);
  }

  Future<void> _load({bool calendars = false}) async {
    setState(() => _loading = true);
    try {
      if (calendars) _calendars = await _api.calendars();
      final from = _gridStart;
      _events = await _api.events(from, from.add(const Duration(days: 42)));
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _goMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _day = _month.year == _today().year && _month.month == _today().month
          ? _today()
          : _month;
    });
    _load();
  }

  void _goToday() {
    setState(() {
      _month = DateTime(_today().year, _today().month);
      _day = _today();
    });
    _load();
  }

  Calendar? _calendarOf(CalendarEvent e) {
    for (final c in _calendars) {
      if (c.id == e.calendarId) return c;
    }
    return null;
  }

  Color _colorOf(CalendarEvent e) =>
      e.color ?? _calendarOf(e)?.color ?? NexusColors.accent;

  List<CalendarEvent> _on(DateTime day) => [
    for (final e in _events)
      if (!_hidden.contains(e.calendarId) && e.isOn(day)) e,
  ];

  Future<void> _edit({CalendarEvent? event}) async {
    final writable = [
      for (final c in _calendars)
        if (c.id != scheduledTasksId) c,
    ];
    if (writable.isEmpty) return;
    var full = event;
    if (event != null && event.isInstance) {
      // An occurrence of a repeating event: edit the series as stored.
      try {
        full = await _api.event(event.id);
      } catch (_) {}
    }
    if (!mounted) return;
    final now = DateTime.now();
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => EventEditor(
          api: _api,
          calendars: writable,
          event: full,
          start: DateTime(_day.year, _day.month, _day.day, now.hour + 1),
        ),
      ),
    );
    if (changed == true) _load();
  }

  void _open(CalendarEvent e) {
    if (e.automationId == null) {
      _edit(event: e);
      return;
    }
    // A scheduled task: its run's chat, or the automation itself.
    if (e.chatId != null) {
      ref.read(chatControllerProvider.notifier).open(e.chatId!);
      Navigator.popUntil(context, (r) => r.isFirst);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ServerPage(
            title: 'Automation',
            path: '/automations/${e.automationId}',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    final dayEvents = _on(_day);
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final month = _MonthGrid(
      start: _gridStart,
      month: _month,
      selected: _day,
      eventsOn: _on,
      colorOf: _colorOf,
      onPick: (d) => setState(() {
        _day = d;
        if (d.month != _month.month) {
          _month = DateTime(d.year, d.month);
          _load();
        }
      }),
      onSwipe: _goMonth,
    );
    final agenda = _Agenda(
      day: _day,
      events: dayEvents,
      colorOf: _colorOf,
      calendarOf: _calendarOf,
      onOpen: _open,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.formatMonthYear(_month)),
        actions: [
          IconButton(
            tooltip: 'Previous month',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _goMonth(-1),
          ),
          IconButton(
            tooltip: 'Next month',
            icon: const Icon(Icons.chevron_right),
            onPressed: () => _goMonth(1),
          ),
          IconButton(
            tooltip: 'Today',
            icon: const Icon(Icons.today),
            onPressed: _goToday,
          ),
          IconButton(
            tooltip: 'Calendars',
            icon: const Icon(Icons.layers_outlined),
            onPressed: _calendarsSheet,
          ),
        ],
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New event',
        onPressed: _calendars.isEmpty ? null : () => _edit(),
        child: const Icon(Icons.add),
      ),
      body: _error != null && _calendars.isEmpty
          ? _ErrorView(error: _error!, retry: () => _load(calendars: true))
          : RefreshIndicator(
              onRefresh: () => _load(calendars: true),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: ListView(children: [month])),
                        const VerticalDivider(width: 1),
                        Expanded(flex: 2, child: agenda),
                      ],
                    )
                  : CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(child: month),
                        const SliverToBoxAdapter(child: Divider(height: 1)),
                        SliverFillRemaining(hasScrollBody: true, child: agenda),
                      ],
                    ),
            ),
    );
  }

  Future<void> _calendarsSheet() async {
    final me = ref.read(sessionProvider).value?.user?['id'];
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final c in _calendars)
                CheckboxListTile(
                  value: !_hidden.contains(c.id),
                  onChanged: (on) {
                    setState(() {
                      on == true ? _hidden.remove(c.id) : _hidden.add(c.id);
                    });
                    setSheet(() {});
                  },
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: c.color,
                  title: Text(c.name),
                  subtitle: c.isDefault ? const Text('Default') : null,
                  secondary: c.isSystem || (me != null && c.userId != me)
                      ? null
                      : PopupMenuButton<String>(
                          onSelected: (v) async {
                            Navigator.pop(sheet);
                            v == 'default'
                                ? await _run(() => _api.makeDefault(c.id))
                                : await _deleteCalendar(c);
                          },
                          itemBuilder: (_) => [
                            if (!c.isDefault)
                              const PopupMenuItem(
                                value: 'default',
                                child: Text('Make default'),
                              ),
                            if (!c.isDefault)
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                          ],
                        ),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New calendar'),
                onTap: () {
                  Navigator.pop(sheet);
                  _newCalendar();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    await _load(calendars: true);
  }

  Future<void> _deleteCalendar(Calendar c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${c.name}?'),
        content: const Text(
          'Its events are deleted too. This can\'t be undone.',
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
    if (ok == true) await _run(() => _api.deleteCalendar(c.id));
  }

  Future<void> _newCalendar() async {
    final name = TextEditingController();
    var color = calendarColors.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setD) => AlertDialog(
          title: const Text('New calendar'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in calendarColors)
                    GestureDetector(
                      onTap: () => setD(() => color = c),
                      child: CircleAvatar(
                        radius: 14,
                        backgroundColor: c,
                        child: c == color
                            ? const Icon(
                                Icons.check,
                                size: 16,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      await _run(() => _api.createCalendar(name.text.trim(), color));
    }
  }
}

/// Colours offered for a new calendar.
const calendarColors = [
  Color(0xFF3B82F6),
  Color(0xFF22C55E),
  Color(0xFFF59E0B),
  Color(0xFFEF4444),
  Color(0xFF8B5CF6),
  Color(0xFFEC4899),
  Color(0xFF14B8A6),
  Color(0xFF6B7280),
];

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.start,
    required this.month,
    required this.selected,
    required this.eventsOn,
    required this.colorOf,
    required this.onPick,
    required this.onSwipe,
  });

  final DateTime start;
  final DateTime month;
  final DateTime selected;
  final List<CalendarEvent> Function(DateTime) eventsOn;
  final Color Function(CalendarEvent) colorOf;
  final ValueChanged<DateTime> onPick;
  final ValueChanged<int> onSwipe;

  @override
  Widget build(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final muted = context.nexus.muted;
    final now = DateTime.now();
    return GestureDetector(
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v.abs() > 200) onSwipe(v < 0 ? 1 : -1);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(
          children: [
            Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          l10n.narrowWeekdays[i],
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            for (var w = 0; w < 6; w++)
              Row(
                children: [
                  for (var d = 0; d < 7; d++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final day = DateTime(
                            start.year,
                            start.month,
                            start.day + w * 7 + d,
                          );
                          final events = eventsOn(day);
                          final isSel = day == selected;
                          final isToday =
                              day.year == now.year &&
                              day.month == now.month &&
                              day.day == now.day;
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => onPick(day),
                            child: SizedBox(
                              height: 52,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 32,
                                    height: 32,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: isSel
                                          ? NexusColors.accent
                                          : isToday
                                          ? scheme.surfaceContainerHigh
                                          : null,
                                    ),
                                    child: Text(
                                      '${day.day}',
                                      style: TextStyle(
                                        fontWeight: isToday || isSel
                                            ? FontWeight.w700
                                            : null,
                                        color: isSel
                                            ? Colors.white
                                            : day.month == month.month
                                            ? null
                                            : muted.withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  SizedBox(
                                    height: 6,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        for (final e in events.take(3))
                                          Container(
                                            width: 5,
                                            height: 5,
                                            margin: const EdgeInsets.symmetric(
                                              horizontal: 1,
                                            ),
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: colorOf(e),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Agenda extends StatelessWidget {
  const _Agenda({
    required this.day,
    required this.events,
    required this.colorOf,
    required this.calendarOf,
    required this.onOpen,
  });

  final DateTime day;
  final List<CalendarEvent> events;
  final Color Function(CalendarEvent) colorOf;
  final Calendar? Function(CalendarEvent) calendarOf;
  final ValueChanged<CalendarEvent> onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    final muted = context.nexus.muted;
    String time(DateTime t) => l10n.formatTimeOfDay(TimeOfDay.fromDateTime(t));
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            l10n.formatFullDate(day),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if (events.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text('Nothing scheduled', style: TextStyle(color: muted)),
          ),
        for (final e in events)
          ListTile(
            onTap: () => onOpen(e),
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: Container(
              width: 4,
              height: 36,
              decoration: BoxDecoration(
                color: colorOf(e),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            title: Text(
              e.title.isEmpty ? '(No title)' : e.title,
              style: e.runStatus == 'error'
                  ? TextStyle(color: Theme.of(context).colorScheme.error)
                  : null,
            ),
            subtitle: Text(
              [
                e.allDay
                    ? 'All day'
                    : e.end == null
                    ? time(e.start)
                    : '${time(e.start)} – ${time(e.end!)}',
                if (e.location?.isNotEmpty == true) e.location!,
                if (e.automationId != null)
                  e.runStatus == null
                      ? 'Scheduled task'
                      : 'Task run · ${e.runStatus}'
                else if (calendarOf(e) != null)
                  calendarOf(e)!.name,
              ].join(' · '),
              style: TextStyle(color: muted),
            ),
            trailing: e.rrule != null
                ? Icon(Icons.repeat, size: 18, color: muted)
                : null,
          ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.retry});
  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Couldn\'t load the calendar.\n$error',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: retry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}
