/// Admin > Events: webhooks the server calls when things happen (sign-ups,
/// chats, config changes...), for every event or a chosen few, and for
/// everyone, system events only, or chosen people and groups.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// Whether [value] is an event in [events], a pattern like user.* that
/// matches some, or * for all.
bool validEventPattern(String value, List<String> events) {
  if (value == '*' || events.contains(value)) return true;
  if (!value.endsWith('.*')) return false;
  final prefix = value.substring(0, value.length - 1);
  return events.any((e) => e.startsWith(prefix));
}

/// [filters] with [value] added: * replaces everything, and anything else
/// replaces *.
List<String> addEventFilter(List<String> filters, String value) =>
    value == '*' ? ['*'] : {...filters.where((f) => f != '*'), value}.toList();

/// Who a webhook is for: null for all, [] for system events only.
String webhookAudience(List? targets) {
  if (targets == null) return 'All users and system events';
  if (targets.isEmpty) return 'System events only';
  final users = targets.where((t) => t is Map && t['type'] == 'user').length;
  final groups = targets.length - users;
  return [
    if (users > 0) users == 1 ? '1 user' : '$users users',
    if (groups > 0) groups == 1 ? '1 group' : '$groups groups',
  ].join(', ');
}

class EventsScreen extends ConsumerStatefulWidget {
  const EventsScreen({super.key});

  @override
  ConsumerState<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends ConsumerState<EventsScreen> {
  List<Map<String, dynamic>>? _hooks;
  List<Map<String, dynamic>> _catalog = [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(clientProvider);
    try {
      final results = await Future.wait([
        client.send('GET', '/api/events'),
        client.send('GET', '/api/events/webhooks'),
      ]);
      _catalog = [
        for (final e in (results[0] as Map?)?['events'] as List? ?? const [])
          if (e is Map) e.cast<String, dynamic>(),
      ]..sort((a, b) => '${a['event']}'.compareTo('${b['event']}'));
      _hooks =
          [
            for (final h in results[1] as List? ?? const [])
              if (h is Map) h.cast<String, dynamic>(),
          ]..sort((a, b) {
            if (a['id'] == 'default') return -1;
            if (b['id'] == 'default') return 1;
            return '${a['name'] ?? ''}'.compareTo('${b['name'] ?? ''}');
          });
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  Future<void> _edit([Map<String, dynamic>? hook]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _WebhookEditor(hook: hook, catalog: _catalog),
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _toggle(Map<String, dynamic> hook, bool on) async {
    try {
      await ref
          .read(clientProvider)
          .send(
            'PUT',
            '/api/events/webhooks/${hook['id']}',
            body: {'enabled': on},
          );
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    _load();
  }

  Future<void> _delete(Map<String, dynamic> hook) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${hook['name'] ?? 'this webhook'}?'),
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
    try {
      await ref
          .read(clientProvider)
          .send('DELETE', '/api/events/webhooks/${hook['id']}');
      if (mounted) _say(context, 'Webhook deleted');
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final hooks = _hooks;
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(title: const Text('Events')),
      floatingActionButton: hooks == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _edit,
              icon: const Icon(Icons.add),
              label: const Text('Add webhook'),
            ),
      body: hooks == null
          ? Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text("Couldn't load the events.\n$_error"),
                    )
                  : const CircularProgressIndicator(),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 88),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(
                      'The server sends each event to the webhooks that '
                      'want it: ${_catalog.length} kinds of events.',
                      style: TextStyle(color: muted),
                    ),
                  ),
                  if (hooks.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No webhooks yet.',
                        style: TextStyle(color: muted),
                      ),
                    ),
                  for (final h in hooks)
                    ListTile(
                      title: Text('${h['name'] ?? 'Webhook'}'),
                      subtitle: Text(
                        [
                          '${h['url'] ?? ''}'.isEmpty
                              ? 'Not configured'
                              : '${h['url']}',
                          (h['events'] as List?)?.contains('*') != false
                              ? 'All events'
                              : '${(h['events'] as List).length} filters',
                          webhookAudience(h['targets'] as List?),
                        ].join(' · '),
                        style: TextStyle(color: muted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _edit(h),
                      onLongPress: h['id'] == 'default'
                          ? null
                          : () => _delete(h),
                      trailing: Switch(
                        value: h['enabled'] == true,
                        onChanged: (on) => _toggle(h, on),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _WebhookEditor extends ConsumerStatefulWidget {
  const _WebhookEditor({this.hook, required this.catalog});
  final Map<String, dynamic>? hook;
  final List<Map<String, dynamic>> catalog;

  @override
  ConsumerState<_WebhookEditor> createState() => _WebhookEditorState();
}

class _WebhookEditorState extends ConsumerState<_WebhookEditor> {
  late final _name = TextEditingController(
    text: '${widget.hook?['name'] ?? ''}',
  );
  late final _url = TextEditingController(text: '${widget.hook?['url'] ?? ''}');
  final _pattern = TextEditingController();
  late bool _enabled = widget.hook?['enabled'] != false;
  late List<String> _events = [
    for (final e in widget.hook?['events'] as List? ?? const ['*']) '$e',
  ];

  /// all, system or selected.
  late String _audience = switch (widget.hook?['targets']) {
    null => 'all',
    List l when l.isEmpty => 'system',
    _ => 'selected',
  };

  /// (type, id) to the name shown.
  final Map<(String, String), String> _targets = {};
  List<Map<String, dynamic>> _groups = [];
  List<Map<String, dynamic>> _found = [];
  bool _busy = false;

  List<String> get _eventNames => [
    for (final e in widget.catalog) '${e['event']}',
  ];

  @override
  void initState() {
    super.initState();
    if (_events.isEmpty) _events = ['*'];
    for (final t in widget.hook?['targets'] as List? ?? const []) {
      if (t is Map) _targets[('${t['type']}', '${t['id']}')] = '${t['id']}';
    }
    _loadNames();
  }

  Future<void> _loadNames() async {
    final client = ref.read(clientProvider);
    try {
      final g = await client.send('GET', '/api/v1/groups/');
      _groups = [
        for (final x in g as List? ?? const [])
          if (x is Map) x.cast<String, dynamic>(),
      ];
      for (final x in _groups) {
        final key = ('group', '${x['id']}');
        if (_targets.containsKey(key)) _targets[key] = '${x['name']}';
      }
    } catch (_) {
      // Groups stay listed by id.
    }
    for (final key in _targets.keys.where((k) => k.$1 == 'user').toList()) {
      try {
        final u = await client.send('GET', '/api/v1/users/${key.$2}');
        _targets[key] = '${(u as Map)['name'] ?? key.$2}';
      } catch (_) {
        // Left as the id.
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) return setState(() => _found = []);
    try {
      final res = await ref
          .read(clientProvider)
          .send(
            'GET',
            '/api/v1/users/',
            query: {'query': q.trim(), 'page': '1'},
          );
      final users = res is Map ? res['users'] : res;
      if (!mounted) return;
      setState(
        () => _found = [
          for (final u in users as List? ?? const [])
            if (u is Map) u.cast<String, dynamic>(),
        ],
      );
    } catch (_) {
      // Nothing found.
    }
  }

  void _addPattern(String value) {
    value = value.trim();
    if (value.isEmpty) return;
    if (!validEventPattern(value, _eventNames)) {
      return _say(context, 'Use a valid event name or pattern like user.*');
    }
    setState(() {
      _events = addEventFilter(_events, value);
      _pattern.clear();
    });
  }

  Future<void> _pickEvent() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _EventPicker(catalog: widget.catalog),
    );
    if (picked != null) _addPattern(picked);
  }

  Future<void> _save() async {
    if (_url.text.trim().isEmpty) return _say(context, 'Give it a URL');
    setState(() => _busy = true);
    final body = {
      'name': _name.text.trim().isEmpty
          ? (widget.hook?['id'] == 'default' ? 'Default webhook' : 'Webhook')
          : _name.text.trim(),
      'url': _url.text.trim(),
      'enabled': _enabled,
      'events': _events.isEmpty ? ['*'] : _events,
      'targets': switch (_audience) {
        'all' => null,
        'system' => <Map>[],
        _ => [
          for (final (type, id) in _targets.keys) {'type': type, 'id': id},
        ],
      },
    };
    try {
      final client = ref.read(clientProvider);
      if (widget.hook == null) {
        await client.send('POST', '/api/events/webhooks', body: body);
      } else {
        await client.send(
          'PUT',
          '/api/events/webhooks/${widget.hook!['id']}',
          body: body,
        );
      }
      if (mounted) {
        _say(context, 'Webhook saved');
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        _say(context, '$e');
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.hook == null ? 'Add webhook' : 'Edit webhook'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Identity audit',
            ),
          ),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'URL'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 8),
          Text('Events', style: Theme.of(context).textTheme.titleSmall),
          Wrap(
            spacing: 6,
            children: [
              for (final e in _events)
                InputChip(
                  label: Text(e == '*' ? 'All events' : e),
                  onDeleted: e == '*'
                      ? null
                      : () => setState(() {
                          _events.remove(e);
                          if (_events.isEmpty) _events = ['*'];
                        }),
                ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pattern,
                  decoration: const InputDecoration(
                    hintText: 'An event or a pattern like user.*',
                  ),
                  onSubmitted: _addPattern,
                ),
              ),
              IconButton(
                tooltip: 'Add',
                icon: const Icon(Icons.add),
                onPressed: () => _addPattern(_pattern.text),
              ),
              IconButton(
                tooltip: 'Choose an event',
                icon: const Icon(Icons.list),
                onPressed: _pickEvent,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Send events for',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          for (final (id, label) in const [
            ('all', 'All users and system events'),
            ('system', 'System events only'),
            ('selected', 'Specific users or groups'),
          ])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(label),
              trailing: _audience == id
                  ? const Icon(Icons.check, color: NexusColors.accent)
                  : null,
              onTap: () => setState(() => _audience = id),
            ),
          if (_audience == 'system')
            Text(
              'Receives matching events that are not associated with a user.',
              style: TextStyle(color: muted),
            ),
          if (_audience == 'selected') ...[
            Wrap(
              spacing: 6,
              children: [
                for (final MapEntry(key: k, value: name) in _targets.entries)
                  InputChip(
                    avatar: Icon(
                      k.$1 == 'group'
                          ? Icons.group_outlined
                          : Icons.person_outline,
                      size: 18,
                    ),
                    label: Text(name),
                    onDeleted: () => setState(() => _targets.remove(k)),
                  ),
              ],
            ),
            TextField(
              decoration: const InputDecoration(
                hintText: 'Search users',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _search,
            ),
            for (final u in _found)
              ListTile(
                dense: true,
                leading: const Icon(Icons.person_outline),
                title: Text('${u['name']}'),
                subtitle: Text('${u['email'] ?? ''}'),
                onTap: () => setState(() {
                  _targets[('user', '${u['id']}')] = '${u['name']}';
                  _found = [];
                }),
              ),
            if (_groups.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Groups', style: TextStyle(color: muted)),
              for (final g in _groups)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${g['name']}'),
                  value: _targets.containsKey(('group', '${g['id']}')),
                  onChanged: (on) => setState(() {
                    final k = ('group', '${g['id']}');
                    on == true
                        ? _targets[k] = '${g['name']}'
                        : _targets.remove(k);
                  }),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

class _EventPicker extends StatefulWidget {
  const _EventPicker({required this.catalog});
  final List<Map<String, dynamic>> catalog;

  @override
  State<_EventPicker> createState() => _EventPickerState();
}

class _EventPickerState extends State<_EventPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final shown = [
      for (final e in widget.catalog)
        if (_q.isEmpty || '${e['event']}'.contains(_q)) e,
    ];
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search events',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final e in shown)
                  ListTile(
                    title: Text('${e['event']}'),
                    subtitle: Text(
                      '${e['description'] ?? ''}',
                      style: TextStyle(color: muted),
                    ),
                    onTap: () => Navigator.pop(context, '${e['event']}'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
