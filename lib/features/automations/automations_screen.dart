import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_drawer.dart' show channelsProvider;
import '../terminal/terminal_screen.dart' show terminalServersProvider;
import 'automations_api.dart';

String _time(BuildContext context, int h, int m) =>
    MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay(hour: h, minute: m));

String _when(BuildContext context, DateTime? t) {
  if (t == null) return 'Not scheduled';
  final l10n = MaterialLocalizations.of(context);
  final now = DateTime.now();
  final time = l10n.formatTimeOfDay(TimeOfDay.fromDateTime(t));
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return 'Today at $time';
  }
  return '${l10n.formatMediumDate(t)}, $time';
}

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

Future<bool> _confirmDelete(BuildContext context, String name) async =>
    await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete "$name"?'),
        content: const Text('Its schedule stops. This can\'t be undone.'),
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
    ) ==
    true;

/// The server's automations, native.
class AutomationsScreen extends ConsumerStatefulWidget {
  const AutomationsScreen({super.key});

  @override
  ConsumerState<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends ConsumerState<AutomationsScreen> {
  late final AutomationsApi _api = AutomationsApi(ref.read(clientProvider));
  List<Automation> _items = const [];
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _items = await _api.list();
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _push(Widget page) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => page),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Automations'),
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New automation',
        onPressed: () => _push(AutomationEditor(api: _api)),
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load automations.\n$_error'),
              )
            else if (!_loading && _items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No automations yet. Tap + to have a model run a prompt on '
                  'a schedule.',
                  style: TextStyle(color: muted),
                ),
              ),
            for (final a in _items)
              ListTile(
                contentPadding: const EdgeInsets.only(left: 20, right: 8),
                title: Text(a.name),
                subtitle: Text(
                  [
                    Schedule.parse(a.rrule)
                        .describe((h, m) => _time(context, h, m)),
                    if (a.active) 'Next: ${_when(context, a.nextRun)}',
                    if (a.lastStatus == 'error') 'Last run failed',
                  ].join(' · '),
                  style: TextStyle(color: muted),
                ),
                onTap: () => _push(AutomationDetail(api: _api, id: a.id)),
                trailing: Switch(
                  value: a.active,
                  onChanged: (_) async {
                    try {
                      await _api.toggle(a.id);
                    } catch (e) {
                      if (context.mounted) _say(context, '$e');
                    }
                    _load();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One automation: what it does, when, and its runs.
class AutomationDetail extends ConsumerStatefulWidget {
  const AutomationDetail({super.key, required this.api, required this.id});
  final AutomationsApi api;
  final String id;

  @override
  ConsumerState<AutomationDetail> createState() => _AutomationDetailState();
}

class _AutomationDetailState extends ConsumerState<AutomationDetail> {
  Automation? _a;
  List<AutomationRun> _runs = const [];
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _a = await widget.api.get(widget.id);
      _runs = await widget.api.runs(widget.id);
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  Future<void> _do(Future<void> Function() action, [String? done]) async {
    setState(() => _busy = true);
    try {
      await action();
      if (done != null && mounted) _say(context, done);
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    final muted = context.nexus.muted;
    final models = ref.watch(modelsProvider).value ?? const [];
    final channels = ref.watch(channelsProvider).value ?? const [];
    final terminals = ref.watch(terminalServersProvider).value ?? const [];
    String modelName(String id) =>
        models.where((m) => m.id == id).firstOrNull?.name ?? id;
    return Scaffold(
      appBar: AppBar(
        title: Text(a?.name ?? 'Automation'),
        actions: [
          if (a != null) ...[
            IconButton(
              tooltip: 'Run now',
              onPressed: _busy
                  ? null
                  : () => _do(() async {
                      await widget.api.run(a.id);
                      // Give the run a moment to show up.
                      await Future<void>.delayed(const Duration(seconds: 2));
                    }, 'Started'),
              icon: const Icon(Icons.play_arrow),
            ),
            IconButton(
              tooltip: 'Edit',
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AutomationEditor(api: widget.api, automation: a),
                  ),
                );
                _load();
              },
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: 'Duplicate',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => AutomationEditor(api: widget.api, copyOf: a),
                ),
              ),
              icon: const Icon(Icons.copy_all_outlined),
            ),
            IconButton(
              tooltip: 'Delete',
              onPressed: () async {
                if (!await _confirmDelete(context, a.name)) return;
                try {
                  await widget.api.delete(a.id);
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  if (context.mounted) _say(context, '$e');
                }
              },
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ],
      ),
      body: _error != null && a == null
          ? Center(child: Text('Couldn\'t load it.\n$_error'))
          : a == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  SwitchListTile(
                    title: Text(a.active ? 'Active' : 'Paused'),
                    value: a.active,
                    onChanged: _busy
                        ? null
                        : (_) => _do(() => widget.api.toggle(a.id)),
                  ),
                  _Row(
                    'Schedule',
                    Schedule.parse(a.rrule)
                        .describe((h, m) => _time(context, h, m)),
                  ),
                  if (a.active) _Row('Next run', _when(context, a.nextRun)),
                  _Row('Model', modelName(a.modelId)),
                  _Row(
                    'Sends to',
                    a.channelId != null
                        ? '# ${channels.where((c) => c.id == a.channelId).firstOrNull?.name ?? 'channel'}'
                        : 'A new chat',
                  ),
                  if (a.data['terminal'] is Map)
                    _Row(
                      'Terminal',
                      [
                        terminals
                                .where(
                                  (t) =>
                                      t.id ==
                                      (a.data['terminal'] as Map)['server_id'],
                                )
                                .firstOrNull
                                ?.name ??
                            '${(a.data['terminal'] as Map)['server_id']}',
                        ?(a.data['terminal'] as Map)['cwd'] as String?,
                      ].join(' · '),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Text('Instructions', style: TextStyle(color: muted)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: SelectableText(a.prompt),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
                    child: Text('Runs', style: TextStyle(color: muted)),
                  ),
                  if (_runs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        'No runs yet',
                        style: TextStyle(color: muted),
                      ),
                    ),
                  for (final r in _runs)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                      ),
                      leading: Icon(
                        switch (r.status) {
                          'success' ||
                          'completed' => Icons.check_circle_outline,
                          'error' => Icons.error_outline,
                          _ => Icons.hourglass_empty,
                        },
                        color: r.status == 'error'
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                      title: Text(_when(context, r.at)),
                      subtitle: Text(
                        r.error?.isNotEmpty == true ? r.error! : r.status,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: r.chatId != null
                          ? const Icon(Icons.chevron_right)
                          : null,
                      onTap: r.chatId == null
                          ? null
                          : () {
                              ref
                                  .read(chatControllerProvider.notifier)
                                  .open(r.chatId!);
                              Navigator.popUntil(context, (r) => r.isFirst);
                            },
                    ),
                ],
              ),
            ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(label, style: TextStyle(color: context.nexus.muted)),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

/// Creating or changing an automation, with the web UI's choices.
class AutomationEditor extends ConsumerStatefulWidget {
  const AutomationEditor({
    super.key,
    required this.api,
    this.automation,
    this.copyOf,
  });
  final AutomationsApi api;

  /// The automation being changed; null for a new one.
  final Automation? automation;

  /// A new automation starts as a copy of this one.
  final Automation? copyOf;

  @override
  ConsumerState<AutomationEditor> createState() => _AutomationEditorState();
}

class _AutomationEditorState extends ConsumerState<AutomationEditor> {
  late final Automation? _a = widget.automation;

  /// Where the fields start from: the automation, or the one copied.
  late final Automation? _from = _a ?? widget.copyOf;
  late final _name = TextEditingController(
    text: widget.copyOf != null
        ? '${widget.copyOf!.name} (copy)'
        : _a?.name ?? '',
  );
  late final _prompt = TextEditingController(text: _from?.prompt ?? '');
  late final _custom = TextEditingController(text: _schedule.custom);
  late final Schedule _schedule = Schedule.parse(_from?.rrule ?? '');
  late String _model = _from?.modelId ?? '';
  late String _channel = _from?.channelId ?? '';
  late String _folder = _from?.folderId ?? '';
  late String _terminal =
      '${(_from?.data['terminal'] as Map?)?['server_id'] ?? ''}';
  late final _cwd = TextEditingController(
    text: '${(_from?.data['terminal'] as Map?)?['cwd'] ?? ''}',
  );
  bool _busy = false;

  Future<void> _save() async {
    if (_name.text.trim().isEmpty ||
        _prompt.text.trim().isEmpty ||
        _model.isEmpty) {
      _say(context, 'Name, instructions and model are needed');
      return;
    }
    if (_schedule.frequency == 'ONCE' &&
        !_schedule.once.isAfter(DateTime.now())) {
      _say(context, 'Pick a time in the future');
      return;
    }
    _schedule.custom = _custom.text.trim();
    setState(() => _busy = true);
    try {
      await widget.api.save(_a?.id, {
        'name': _name.text.trim(),
        'folder_id': _channel.isNotEmpty || _folder.isEmpty ? null : _folder,
        'data': {
          // Anything else it carries stays as it was.
          ...?_from?.data,
          'prompt': _prompt.text.trim(),
          'model_id': _model,
          'rrule': _schedule.build(),
          'target': _channel.isEmpty
              ? {'type': 'chat'}
              : {'type': 'channel', 'channel_id': _channel},
          'terminal': _terminal.isEmpty
              ? null
              : {
                  'server_id': _terminal,
                  if (_cwd.text.trim().isNotEmpty) 'cwd': _cwd.text.trim(),
                },
        },
        'is_active': _a?.active ?? true,
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        _say(context, '$e');
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final models = ref.watch(modelsProvider).value ?? const [];
    final channels = ref.watch(channelsProvider).value ?? const [];
    final folders = ref.watch(foldersProvider).value ?? const [];
    final terminals = ref.watch(terminalServersProvider).value ?? const [];
    if (_model.isEmpty && models.isNotEmpty) _model = models.first.id;
    final s = _schedule;
    Widget dropdown<T>(
      IconData icon,
      T value,
      List<(T, String)> items,
      ValueChanged<T> onChanged,
    ) => ListTile(
      leading: Icon(icon),
      title: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: items.any((i) => i.$1 == value) ? value : null,
          isExpanded: true,
          onChanged: (v) => setState(() => onChanged(v as T)),
          items: [
            for (final (v, label) in items)
              DropdownMenuItem(
                value: v,
                child: Text(label, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(_a == null ? 'New automation' : 'Edit automation'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_a == null ? 'Create' : 'Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _name,
              autofocus: _a == null,
              style: const TextStyle(fontSize: 20),
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Automation title',
                border: InputBorder.none,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _prompt,
              minLines: 5,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Instructions',
                hintText: 'What the model should do each time',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 8),
          dropdown<String>(
            Icons.repeat,
            s.frequency,
            const [
              ('ONCE', 'Once'),
              ('HOURLY', 'Hourly'),
              ('DAILY', 'Daily'),
              ('WEEKLY', 'Weekly'),
              ('MONTHLY', 'Monthly'),
              ('CUSTOM', 'Custom rule'),
            ],
            (v) {
              if (v == 'CUSTOM' && _custom.text.isEmpty) {
                _custom.text = s.build();
              }
              s.frequency = v;
            },
          ),
          if (s.frequency == 'ONCE')
            ListTile(
              leading: const SizedBox(),
              title: Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: s.once,
                        firstDate: DateTime.now(),
                        lastDate: DateTime(2100),
                      );
                      if (d != null) {
                        setState(
                          () => s.once = DateTime(
                            d.year,
                            d.month,
                            d.day,
                            s.once.hour,
                            s.once.minute,
                          ),
                        );
                      }
                    },
                    child: Text(
                      MaterialLocalizations.of(context)
                          .formatMediumDate(s.once),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final t = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(s.once),
                      );
                      if (t != null) {
                        setState(
                          () => s.once = DateTime(
                            s.once.year,
                            s.once.month,
                            s.once.day,
                            t.hour,
                            t.minute,
                          ),
                        );
                      }
                    },
                    child: Text(_time(context, s.once.hour, s.once.minute)),
                  ),
                ],
              ),
            ),
          if (s.frequency == 'HOURLY')
            dropdown<int>(Icons.timelapse, s.interval, [
              for (final n in [1, 2, 3, 4, 6, 8, 12])
                (n, n == 1 ? 'Every hour' : 'Every $n hours'),
            ], (v) => s.interval = v),
          if (s.frequency == 'HOURLY')
            dropdown<int>(Icons.more_time, s.minute, [
              for (final m in [0, 5, 10, 15, 20, 30, 45]) (m, 'At minute $m'),
            ], (v) => s.minute = v),
          if (s.frequency == 'WEEKLY')
            Padding(
              padding: const EdgeInsets.fromLTRB(72, 0, 16, 0),
              child: Wrap(
                spacing: 6,
                children: [
                  for (final d in Schedule.weekDays)
                    FilterChip(
                      label: Text(d[0] + d.substring(1).toLowerCase()),
                      selected: s.days.contains(d),
                      onSelected: (on) =>
                          setState(() => on ? s.days.add(d) : s.days.remove(d)),
                    ),
                ],
              ),
            ),
          if (s.frequency == 'MONTHLY')
            dropdown<int>(Icons.event, s.monthDay, [
              for (var d = 1; d <= 31; d++) (d, 'On day $d'),
            ], (v) => s.monthDay = v),
          if (['DAILY', 'WEEKLY', 'MONTHLY'].contains(s.frequency))
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('At'),
              trailing: TextButton(
                onPressed: () async {
                  final t = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(hour: s.hour, minute: s.minute),
                  );
                  if (t != null) {
                    setState(() {
                      s.hour = t.hour;
                      s.minute = t.minute;
                    });
                  }
                },
                child: Text(_time(context, s.hour, s.minute)),
              ),
            ),
          if (s.frequency == 'CUSTOM')
            Padding(
              padding: const EdgeInsets.fromLTRB(72, 0, 20, 8),
              child: TextField(
                controller: _custom,
                maxLines: null,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: 'RRULE',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          const Divider(),
          dropdown<String>(Icons.auto_awesome_outlined, _model, [
            for (final m in models) (m.id, m.name),
          ], (v) => _model = v),
          dropdown<String>(Icons.send_outlined, _channel, [
            ('', 'A new chat'),
            for (final c in channels) (c.id, '# ${c.name}'),
          ], (v) => _channel = v),
          if (_channel.isEmpty)
            dropdown<String>(Icons.folder_outlined, _folder, [
              ('', 'No folder'),
              for (final f in folders) (f.id, f.name),
            ], (v) => _folder = v),
          if (terminals.isNotEmpty || _terminal.isNotEmpty)
            dropdown<String>(Icons.terminal, _terminal, [
              ('', 'No terminal'),
              for (final t in terminals) (t.id, t.name),
            ], (v) => _terminal = v),
          if (_terminal.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(72, 0, 20, 8),
              child: TextField(
                controller: _cwd,
                decoration: const InputDecoration(
                  labelText: 'Working folder (optional)',
                  hintText: 'Where its commands run',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
