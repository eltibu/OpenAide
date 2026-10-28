import 'package:flutter/material.dart';

import '../../core/widgets/empty_state.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/theme.dart';
import 'code_editor.dart';
import 'skill_files.dart';
import 'access_editor.dart' show ItemMenu;
import '../chat/chat_controller.dart' show skillsProvider;
import 'owner_filter.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

String _seg(String id) => Uri.encodeComponent(id);

final _toolsListProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final res = await ref.watch(clientProvider).send('GET', '/api/v1/tools/');
  return [
    for (final t in (res as List? ?? const []).whereType<Map>())
      t.cast<String, dynamic>(),
  ];
});

final _skillsListProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final res = await ref.watch(clientProvider).send('GET', '/api/v1/skills/');
  return [
    for (final t in (res as List? ?? const []).whereType<Map>())
      t.cast<String, dynamic>(),
  ];
});

String _description(Map<String, dynamic> j) =>
    '${j['description'] ?? (j['meta'] as Map?)?['description'] ?? ''}';

/// The server's tools: what each can do, its code, and its settings.
class ToolsScreen extends ConsumerWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_toolsListProvider);
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tools'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'New Tool',
            icon: const Icon(Icons.add),
            onSelected: (v) async {
              final saved = v == 'url'
                  ? await importCodeFromUrl(context, ref, 'tool')
                  : await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const CodeItemEditor(kind: 'tool'),
                          ),
                        ) ==
                        true;
              if (saved) ref.invalidate(_toolsListProvider);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'new', child: Text('New Tool')),
              if (ref.read(sessionProvider).value?.user?['role'] == 'admin')
                const PopupMenuItem(
                  value: 'url',
                  child: Text('Import from URL'),
                ),
            ],
          ),
          const OwnerFilterButton(),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(_toolsListProvider.future),
        child: list.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load tools.\n$e'),
              ),
            ],
          ),
          data: (items) => ListView(
            children: [
              if (items.isEmpty)
                const EmptyState(
                  icon: Icons.build_outlined,
                  title: 'No tools yet',
                ),
              for (final t in ownerFiltered(ref, items, (t) => t['user_id']))
                ListTile(
                  leading: const Icon(Icons.build_outlined),
                  title: Text('${t['name'] ?? t['id']}'),
                  subtitle: _description(t).isEmpty
                      ? null
                      : Text(
                          _description(t),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: muted),
                        ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ToolDetail(id: '${t['id']}'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A clone's id: tool ids must be Python names, so letters, digits and _.
String cloneToolId(String id, DateTime now) =>
    '${id.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}_copy_${now.millisecondsSinceEpoch % 100000}'
        .toLowerCase();

class ToolDetail extends ConsumerStatefulWidget {
  const ToolDetail({super.key, required this.id});
  final String id;

  @override
  ConsumerState<ToolDetail> createState() => _ToolDetailState();
}

class _ToolDetailState extends ConsumerState<ToolDetail> {
  late final OpenWebUiClient _client = ref.read(clientProvider);
  Map<String, dynamic>? _tool;
  Object? _error;

  String get _base => '/api/v1/tools/id/${_seg(widget.id)}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _tool = ((await _client.send('GET', _base)) as Map)
          .cast<String, dynamic>();
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  /// A copy under a new id, as the web's Clone; opened in its place.
  Future<void> _clone() async {
    final t = _tool!;
    final id = cloneToolId(widget.id, DateTime.now());
    try {
      await _client.send(
        'POST',
        '/api/v1/tools/create',
        body: {
          'id': id,
          'name': '${t['name'] ?? widget.id} (copy)',
          'content': t['content'] ?? '',
          'meta': t['meta'] ?? {},
        },
      );
      ref.invalidate(_toolsListProvider);
      if (mounted) {
        await Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(builder: (_) => ToolDetail(id: id)),
        );
      }
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _tool;
    final muted = context.nexus.muted;
    final admin = ref.read(sessionProvider).value?.user?['role'] == 'admin';
    final specs = (t?['specs'] as List? ?? const []).whereType<Map>();
    return Scaffold(
      appBar: AppBar(
        title: Text('${t?['name'] ?? 'Tool'}'),
        actions: [
          if (t != null)
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final saved = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CodeItemEditor(kind: 'tool', id: widget.id),
                  ),
                );
                if (saved == true) {
                  ref.invalidate(_toolsListProvider);
                  await _load();
                }
              },
            ),
          if (t != null)
            ItemMenu(
              kind: 'tool',
              id: widget.id,
              name: '${t['name'] ?? ''}',
              onClone: _clone,
              onRestored: _load,
            ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Couldn\'t load it.\n$_error'))
          : t == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                if (_description(t).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    child: Text(_description(t)),
                  ),
                ListTile(
                  leading: const Icon(Icons.tune),
                  title: const Text('My settings'),
                  subtitle: const Text('Values this tool uses for you'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ValvesScreen(
                        title: 'My settings',
                        specPath: '$_base/valves/user/spec',
                        valuesPath: '$_base/valves/user',
                        savePath: '$_base/valves/user/update',
                      ),
                    ),
                  ),
                ),
                if (admin)
                  ListTile(
                    leading: const Icon(Icons.admin_panel_settings_outlined),
                    title: const Text('Settings for everyone'),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ValvesScreen(
                          title: 'Settings for everyone',
                          specPath: '$_base/valves/spec',
                          valuesPath: '$_base/valves',
                          savePath: '$_base/valves/update',
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Text('What it can do', style: TextStyle(color: muted)),
                ),
                for (final s in specs)
                  ListTile(
                    dense: true,
                    title: Text(
                      '${s['name']}',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    subtitle: Text('${s['description'] ?? ''}'),
                  ),
                if ('${t['content'] ?? ''}'.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Text('Code', style: TextStyle(color: muted)),
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SelectableText(
                        '${t['content']}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

/// A tool's settings, as a form built from what it declares.
class ValvesScreen extends ConsumerStatefulWidget {
  const ValvesScreen({
    super.key,
    required this.title,
    required this.specPath,
    required this.valuesPath,
    required this.savePath,
  });
  final String title;
  final String specPath;
  final String valuesPath;
  final String savePath;

  @override
  ConsumerState<ValvesScreen> createState() => _ValvesScreenState();
}

class _ValvesScreenState extends ConsumerState<ValvesScreen> {
  late final OpenWebUiClient _client = ref.read(clientProvider);
  Map<String, dynamic> _props = {};
  final Map<String, Object?> _values = {};
  final Map<String, TextEditingController> _text = {};

  /// Settings given a value of their own; the rest stay on Default (the
  /// tool's own), as the web's Default / Custom switch.
  final Set<String> _custom = {};
  List<Object?> _required = const [];
  bool _loading = true;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final spec = await _client.send('GET', widget.specPath);
      final values = await _client.send('GET', widget.valuesPath);
      _props =
          ((spec as Map?)?['properties'] as Map?)?.cast<String, dynamic>() ??
          {};
      _required = (spec?['required'] as List?) ?? const [];
      for (final e in _props.entries) {
        final p = (e.value as Map).cast<String, dynamic>();
        final saved = (values as Map?)?[e.key];
        if (saved != null) _custom.add(e.key);
        final v = saved ?? p['default'];
        _values[e.key] = v;
        if (p['type'] != 'boolean' && p['enum'] == null) {
          _text[e.key] = TextEditingController(text: v == null ? '' : '$v');
        }
      }
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final out = <String, Object?>{};
    for (final e in _props.entries) {
      final p = (e.value as Map).cast<String, dynamic>();
      final type = p['type'] ?? (p['anyOf'] as List?)?.firstOrNull?['type'];
      if (!_custom.contains(e.key)) {
        out[e.key] = null;
      } else if (_text.containsKey(e.key)) {
        final t = _text[e.key]!.text;
        out[e.key] = switch (type) {
          'integer' => int.tryParse(t),
          'number' => num.tryParse(t),
          _ => t.isEmpty && p['default'] == null ? null : t,
        };
      } else {
        out[e.key] = _values[e.key];
      }
    }
    setState(() => _busy = true);
    try {
      await _client.send('POST', widget.savePath, body: out);
      if (mounted) {
        _say(context, 'Saved');
        Navigator.pop(context);
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
        title: Text(widget.title),
        actions: [
          if (_props.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('Save'),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('Couldn\'t load settings.\n$_error'))
          : _props.isEmpty
          ? Center(
              child: Text(
                'Nothing to set here',
                style: TextStyle(color: muted),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                for (final e in _props.entries)
                  Builder(
                    builder: (context) {
                      final p = (e.value as Map).cast<String, dynamic>();
                      final label = '${p['title'] ?? e.key}';
                      final help = p['description'] as String?;
                      final required = _required.contains(e.key);
                      if (!_custom.contains(e.key)) {
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(label),
                          subtitle: Text(
                            [required ? 'None' : 'Default', ?help].join(' · '),
                          ),
                          trailing: TextButton(
                            onPressed: () => setState(() => _custom.add(e.key)),
                            child: const Text('Custom'),
                          ),
                        );
                      }
                      final toDefault = Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () =>
                              setState(() => _custom.remove(e.key)),
                          child: Text(required ? 'None' : 'Default'),
                        ),
                      );
                      Widget withDefault(Widget field) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [field, toDefault],
                      );
                      if (p['type'] == 'boolean') {
                        return withDefault(
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(label),
                            subtitle: help == null ? null : Text(help),
                            value: _values[e.key] == true,
                            onChanged: (v) =>
                                setState(() => _values[e.key] = v),
                          ),
                        );
                      }
                      if (p['enum'] is List) {
                        return withDefault(
                          DropdownButtonFormField<String>(
                            initialValue: _values[e.key]?.toString(),
                            decoration: InputDecoration(
                              labelText: label,
                              helperText: help,
                            ),
                            items: [
                              for (final o in p['enum'] as List)
                                DropdownMenuItem(
                                  value: '$o',
                                  child: Text('$o'),
                                ),
                            ],
                            onChanged: (v) =>
                                setState(() => _values[e.key] = v),
                          ),
                        );
                      }
                      final secret =
                          p['input'] is Map &&
                          (p['input'] as Map)['type'] == 'password';
                      return withDefault(
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: TextField(
                            controller: _text[e.key],
                            obscureText: secret,
                            keyboardType:
                                p['type'] == 'integer' || p['type'] == 'number'
                                ? TextInputType.number
                                : null,
                            maxLines: secret ? 1 : null,
                            decoration: InputDecoration(
                              labelText: label,
                              helperText: help,
                              helperMaxLines: 3,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
    );
  }
}

/// The server's skills: turn them on or off, read and change them.
class SkillsScreen extends ConsumerWidget {
  const SkillsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_skillsListProvider);
    final muted = context.nexus.muted;
    final client = ref.read(clientProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Skills'),
        actions: [
          IconButton(
            tooltip: 'Import',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () async {
              final done = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => const SkillImportScreen()),
              );
              if (done == true) {
                ref.invalidate(_skillsListProvider);
                ref.invalidate(skillsProvider);
              }
            },
          ),
          const OwnerFilterButton(),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(_skillsListProvider.future),
        child: list.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load skills.\n$e'),
              ),
            ],
          ),
          data: (items) => ListView(
            children: [
              if (items.isEmpty)
                const EmptyState(
                  icon: Icons.psychology_outlined,
                  title: 'No skills yet',
                ),
              for (final s in ownerFiltered(ref, items, (s) => s['user_id']))
                ListTile(
                  leading: const Icon(Icons.psychology_outlined),
                  title: Text('${s['name'] ?? s['id']}'),
                  subtitle: _description(s).isEmpty
                      ? null
                      : Text(
                          _description(s),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: muted),
                        ),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => SkillEditor(id: '${s['id']}'),
                      ),
                    );
                    ref.invalidate(_skillsListProvider);
                    ref.invalidate(skillsProvider);
                  },
                  trailing: Switch(
                    value: s['is_active'] != false,
                    onChanged: (_) async {
                      try {
                        await client.send(
                          'POST',
                          '/api/v1/skills/id/${_seg('${s['id']}')}/toggle',
                        );
                      } catch (e) {
                        if (context.mounted) _say(context, '$e');
                      }
                      ref.invalidate(_skillsListProvider);
                      ref.invalidate(skillsProvider);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class SkillEditor extends ConsumerStatefulWidget {
  const SkillEditor({super.key, required this.id});
  final String id;

  @override
  ConsumerState<SkillEditor> createState() => _SkillEditorState();
}

class _SkillEditorState extends ConsumerState<SkillEditor> {
  late final OpenWebUiClient _client = ref.read(clientProvider);
  Map<String, dynamic>? _s;
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _content = TextEditingController();
  Object? _error;
  bool _busy = false;

  String get _base => '/api/v1/skills/id/${_seg(widget.id)}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = ((await _client.send('GET', _base)) as Map)
          .cast<String, dynamic>();
      _s = s;
      _name.text = '${s['name'] ?? ''}';
      _description.text = '${s['description'] ?? ''}';
      _content.text = '${s['content'] ?? ''}';
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      // Only what changed here; the skill's files stay as they are.
      await _client.send(
        'POST',
        '$_base/update',
        body: {
          'id': widget.id,
          'name': _name.text.trim(),
          'description': _description.text.trim(),
          'content': _content.text,
          'meta': _s?['meta'] ?? {},
          'is_active': _s?['is_active'] ?? true,
        },
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        _say(context, '$e');
        setState(() => _busy = false);
      }
    }
  }

  /// A copy with its own id, opened to edit.
  Future<void> _clone() async {
    final id =
        '${widget.id}-copy-${DateTime.now().millisecondsSinceEpoch % 100000}';
    try {
      await _client.send(
        'POST',
        '/api/v1/skills/create',
        body: {
          'id': id,
          'name': '${_name.text} (copy)',
          'description': _description.text,
          'content': _content.text,
          'meta': _s?['meta'] ?? {},
        },
      );
      ref.invalidate(skillsProvider);
      if (mounted) {
        await Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(builder: (_) => SkillEditor(id: id)),
        );
      }
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${_name.text}?'),
        content: const Text('This can\'t be undone.'),
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
      await _client.send('DELETE', '$_base/delete');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Skill'),
      actions: [
        if (_s != null) ...[
          IconButton(
            tooltip: 'Delete',
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
          ),
          ItemMenu(
            kind: 'skill',
            id: widget.id,
            name: _name.text,
            onClone: _clone,
            onRestored: _load,
            extra: [
              (
                'Files',
                () async {
                  final changed = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SkillFilesScreen(
                        id: widget.id,
                        name: '${_s?['name'] ?? _name.text}',
                      ),
                    ),
                  );
                  if (changed == true) _load();
                },
              ),
              ('Export .skill', () => exportSkillFile(context, ref, widget.id)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ],
    ),
    body: _error != null
        ? Center(child: Text('Couldn\'t load it.\n$_error'))
        : _s == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: _description,
                maxLines: null,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _content,
                minLines: 10,
                maxLines: null,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Instructions',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
  );
}

/// Workspace: the server's models, knowledge, prompts, tools and skills.
class WorkspaceScreen extends StatelessWidget {
  const WorkspaceScreen({super.key, required this.sections});

  /// (icon, title, subtitle, page) for each part the server offers.
  final List<(IconData, String, String, Widget Function())> sections;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Workspace')),
    body: ListView(
      children: [
        for (final (icon, title, subtitle, page) in sections)
          ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => page()),
            ),
          ),
      ],
    ),
  );
}
