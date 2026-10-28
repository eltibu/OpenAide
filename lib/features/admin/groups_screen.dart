/// Admin > Users > Groups and default permissions, as on the web: what
/// everyone may do, and groups that give their members more.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart' show modelsProvider;
import 'admin_api.dart';
import 'config_editor.dart' show settingLabel;
import '../../core/i18n/app_strings.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(text))));

/// "public_models" as "Public models".
String permissionLabel(String key) => switch (key) {
  'stt' => 'Speech to text',
  'tts' => 'Text to speech',
  'api_keys' => 'API keys',
  _ => settingLabel(key.toUpperCase()),
};

/// [base] with every on/off in [over] put in its place; keys only in
/// [base] start off, so a group gives nothing it doesn't name.
Map<String, dynamic> permissionsFor(Map base, Map? over, {bool fill = false}) {
  final out = <String, dynamic>{};
  for (final MapEntry(:key, :value) in base.entries) {
    final mine = over?[key];
    out['$key'] = value is Map
        ? permissionsFor(value, mine is Map ? mine : null, fill: fill)
        : mine is bool
        ? mine
        : (fill ? false : value);
  }
  return out;
}

/// Groups in tree order, each with how deep it sits under its parents.
/// A group whose parent is gone sits at the top.
List<(Map<String, dynamic>, int)> groupTree(
  List<Map<String, dynamic>> groups, {
  Set<String>? collapsed,
}) {
  final ids = {for (final g in groups) '${g['id']}'};
  final kids = <String?, List<Map<String, dynamic>>>{};
  for (final g in groups) {
    final parent = '${g['parent_group_id'] ?? ''}';
    kids.putIfAbsent(ids.contains(parent) ? parent : null, () => []).add(g);
  }
  for (final list in kids.values) {
    list.sort(
      (a, b) =>
          '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()),
    );
  }
  final out = <(Map<String, dynamic>, int)>[];
  final seen = <String>{};
  void add(String? parent, int depth) {
    for (final g in kids[parent] ?? const <Map<String, dynamic>>[]) {
      final id = '${g['id']}';
      if (!seen.add(id)) continue;
      out.add((g, depth));
      if (!(collapsed?.contains(id) ?? false)) add(id, depth + 1);
    }
  }

  add(null, 0);
  return out;
}

/// [id] and every group under it, which can't become its parent.
Set<String> groupAndBelow(List<Map<String, dynamic>> groups, String id) {
  final out = {id};
  var grew = true;
  while (grew) {
    grew = false;
    for (final g in groups) {
      if (out.contains('${g['parent_group_id']}') && out.add('${g['id']}')) {
        grew = true;
      }
    }
  }
  return out;
}

/// The emails in a "Name,Email" file, and the rows that aren't one.
(List<String>, List<int>) parseGroupCsv(String csv) {
  final emails = <String>[];
  final bad = <int>[];
  final rows = csv.split(RegExp(r'\r?\n')).skip(1).toList();
  for (final (i, row) in rows.indexed) {
    final cols = [for (final c in row.split(',')) c.trim()];
    if (cols.length == 1 && cols.first.isEmpty) continue;
    final email = cols.length == 2 ? cols[1].toLowerCase() : '';
    if (email.isEmpty) {
      bad.add(i + 1);
    } else if (!emails.contains(email)) {
      emails.add(email);
    }
  }
  return (emails, bad);
}

/// Who may share things with a group.
const groupShareOptions = {
  'false': 'No one',
  'members': 'Members',
  'true': 'Anyone',
};

/// Switches for a tree of permissions, a heading per part.
class PermissionsEditor extends StatelessWidget {
  const PermissionsEditor({
    super.key,
    required this.permissions,
    required this.onChanged,
  });
  final Map<String, dynamic> permissions;
  final VoidCallback onChanged;

  static String _part(String key) => switch (key) {
    'workspace' => 'Workspace',
    'sharing' => 'Sharing',
    'access_grants' => 'Sharing with',
    'chat' => 'Chat',
    'features' => 'Features',
    'settings' => 'Settings',
    _ => permissionLabel(key),
  };

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    void add(Map<String, dynamic> m, String? heading) {
      if (heading != null) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text(heading, style: Theme.of(context).textTheme.titleSmall),
          ),
        );
      }
      for (final key in m.keys) {
        final v = m[key];
        if (v is Map) {
          add(v.cast<String, dynamic>(), _part(key));
        } else if (v is bool) {
          children.add(
            StatefulBuilder(
              builder: (context, set) => SwitchListTile(
                title: Text(permissionLabel(key)),
                value: m[key] as bool,
                onChanged: (on) {
                  set(() => m[key] = on);
                  onChanged();
                },
              ),
            ),
          );
        }
      }
    }

    add(permissions, null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// What every user may do unless a group gives more.
class DefaultPermissionsScreen extends ConsumerStatefulWidget {
  const DefaultPermissionsScreen({super.key});

  @override
  ConsumerState<DefaultPermissionsScreen> createState() =>
      _DefaultPermissionsScreenState();
}

class _DefaultPermissionsScreenState
    extends ConsumerState<DefaultPermissionsScreen> {
  Map<String, dynamic>? _perms;
  Object? _error;
  bool _dirty = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load('/api/v1/users/default/permissions');
  }

  Future<void> _load(String path, {bool dirty = false}) async {
    try {
      final res = await ref.read(clientProvider).send('GET', path);
      _perms = (jsonDecode(jsonEncode(res)) as Map).cast<String, dynamic>();
      _dirty = dirty;
      _generation++;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    try {
      await ref
          .read(clientProvider)
          .send('POST', '/api/v1/users/default/permissions', body: _perms);
      if (mounted) {
        _say(context, 'Saved');
        setState(() => _dirty = false);
      }
    } catch (e) {
      if (mounted) _say(context, 'Not saved: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const T('Default permissions'),
      actions: [
        PopupMenuButton<String>(
          onSelected: (_) =>
              _load('/api/v1/users/default/permissions/defaults', dirty: true),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'reset', child: T('Reset to defaults')),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(
            onPressed: _dirty ? _save : null,
            child: const T('Save'),
          ),
        ),
      ],
    ),
    body: _perms == null
        ? Center(
            child: _error != null
                ? Text('Couldn\'t load permissions.\n$_error')
                : const CircularProgressIndicator(),
          )
        : ListView(
            key: ValueKey(_generation),
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: T(
                  'Everyone gets these. Groups can give their members more.',
                  style: TextStyle(color: context.nexus.muted),
                ),
              ),
              PermissionsEditor(
                permissions: _perms!,
                onChanged: () {
                  if (!_dirty) setState(() => _dirty = true);
                },
              ),
            ],
          ),
  );
}

final groupsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((
  ref,
) async {
  final res = await ref.watch(clientProvider).send('GET', '/api/v1/groups/');
  return [
    for (final g in res as List? ?? const [])
      if (g is Map) g.cast<String, dynamic>(),
  ];
});

/// Every group, with what it gives and who is in it.
class GroupsScreen extends ConsumerStatefulWidget {
  const GroupsScreen({super.key});

  @override
  ConsumerState<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends ConsumerState<GroupsScreen> {
  /// Groups whose subgroups are folded away.
  final _closed = <String>{};

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final about = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const T('New group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: InputDecoration(labelText: tr('Name')),
            ),
            TextField(
              controller: about,
              decoration: InputDecoration(labelText: tr('Description')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const T('Create'),
          ),
        ],
      ),
    );
    final n = name.text.trim();
    final a = about.text.trim();
    name.dispose();
    about.dispose();
    if (ok != true || n.isEmpty) return;
    try {
      final made = await ref
          .read(clientProvider)
          .send(
            'POST',
            '/api/v1/groups/create',
            body: {'name': n, 'description': a},
          );
      ref.invalidate(groupsProvider);
      if (context.mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => GroupEditor(
              group: (made as Map).cast<String, dynamic>(),
              groups: ref.read(groupsProvider).value ?? const [],
            ),
          ),
        );
        ref.invalidate(groupsProvider);
      }
    } catch (e) {
      if (context.mounted) _say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(groupsProvider);
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(title: const T('Groups')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context, ref),
        icon: const Icon(Icons.group_add_outlined),
        label: const T('New group'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(groupsProvider.future),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const T('Default permissions'),
              subtitle: const T('What everyone may do'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const DefaultPermissionsScreen(),
                ),
              ),
            ),
            const Divider(),
            ...groups.when(
              loading: () => [
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
              error: (e, _) => [ListTile(title: Text('$e'))],
              data: (list) => [
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: T('No groups yet.', style: TextStyle(color: muted)),
                  ),
                for (final (g, depth) in groupTree(list, collapsed: _closed))
                  ListTile(
                    contentPadding: EdgeInsetsDirectional.only(
                      start: 16.0 + 20 * depth.clamp(0, 6),
                      end: 8,
                    ),
                    leading: const CircleAvatar(
                      child: Icon(Icons.groups_outlined),
                    ),
                    trailing: list.any((c) => c['parent_group_id'] == g['id'])
                        ? IconButton(
                            tooltip: _closed.contains('${g['id']}')
                                ? 'Expand ${g['name']}'
                                : 'Collapse ${g['name']}',
                            icon: Icon(
                              _closed.contains('${g['id']}')
                                  ? Icons.expand_more
                                  : Icons.expand_less,
                            ),
                            onPressed: () => setState(() {
                              final id = '${g['id']}';
                              if (!_closed.remove(id)) _closed.add(id);
                            }),
                          )
                        : null,
                    title: Text('${g['name']}'),
                    subtitle: Text(
                      [
                        if ('${g['description'] ?? ''}'.isNotEmpty)
                          '${g['description']}',
                        '${g['member_count'] ?? 0} members',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => GroupEditor(group: g, groups: list),
                        ),
                      );
                      ref.invalidate(groupsProvider);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One group: its name, members and the permissions it gives.
class GroupEditor extends ConsumerStatefulWidget {
  const GroupEditor({super.key, required this.group, this.groups = const []});
  final Map<String, dynamic> group;

  /// Every group, to pick a parent from.
  final List<Map<String, dynamic>> groups;

  @override
  ConsumerState<GroupEditor> createState() => _GroupEditorState();
}

class _GroupEditorState extends ConsumerState<GroupEditor> {
  late final _name = TextEditingController(text: '${widget.group['name']}');
  late final _about = TextEditingController(
    text: '${widget.group['description'] ?? ''}',
  );
  Map<String, dynamic>? _perms;
  List<Map<String, dynamic>> _members = const [];
  List<Map<String, dynamic>> _inherited = const [];
  bool _showInherited = false;
  Map<String, dynamic>? _preview;
  bool _dirty = false;
  bool _importing = false;
  late String? _parent = widget.group['parent_group_id'] as String?;
  late final Map<String, dynamic> _data = jsonDecode(
    jsonEncode(widget.group['data'] ?? {}),
  ) as Map<String, dynamic>;

  Map<String, dynamic> get _config =>
      (_data['config'] as Map<String, dynamic>?) ??
      (_data['config'] = <String, dynamic>{});
  List<String> get _defaultModels => [
    for (final m in _config['default_models'] as List? ?? const []) '$m',
  ];

  String get _id => '${widget.group['id']}';
  String get _base => '/api/v1/groups/id/${Uri.encodeComponent(_id)}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final client = ref.read(clientProvider);
    try {
      // The full set of switches comes from the defaults; a group only
      // gives what it names.
      final base = await client.send(
        'GET',
        '/api/v1/users/default/permissions/defaults',
      );
      _perms ??= permissionsFor(
        base as Map,
        widget.group['permissions'] as Map?,
        fill: true,
      );
      await _loadMembers();
      await _loadPreview();
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadPreview() async {
    try {
      final res = await ref.read(clientProvider).send('GET', '$_base/preview');
      if (mounted) setState(() => _preview = (res as Map).cast());
    } catch (_) {}
  }

  Future<void> _loadMembers() async {
    final res = await ref
        .read(clientProvider)
        .send('GET', '$_base/members', query: {'membership': 'direct'});
    _members = [
      for (final u in (res as Map)['items'] as List? ?? const [])
        if (u is Map) u.cast<String, dynamic>(),
    ];
    final from = await ref
        .read(clientProvider)
        .send('GET', '$_base/members', query: {'membership': 'inherited'});
    _inherited = [
      for (final u in (from as Map)['items'] as List? ?? const [])
        if (u is Map) u.cast<String, dynamic>(),
    ];
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    try {
      await ref
          .read(clientProvider)
          .send(
            'POST',
            '$_base/update',
            body: {
              'name': _name.text.trim(),
              'description': _about.text.trim(),
              'permissions': _perms,
              'data': _data,
              'parent_group_id': _parent,
            },
          );
      widget.group['parent_group_id'] = _parent;
      await _loadPreview();
      if (mounted) {
        _say(context, 'Saved');
        setState(() => _dirty = false);
      }
    } catch (e) {
      if (mounted) _say(context, 'Not saved: $e');
    }
  }

  Future<void> _addMember() async {
    final api = AdminApi(ref.read(clientProvider));
    final have = {for (final m in _members) '${m['id']}'};
    final picked = await showModalBottomSheet<AdminUser>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _UserPicker(api: api, skip: have),
    );
    if (picked == null) return;
    try {
      await ref
          .read(clientProvider)
          .send(
            'POST',
            '$_base/users/add',
            body: {
              'user_ids': [picked.id],
            },
          );
      await _loadMembers();
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  Future<void> _importCsv() async {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    setState(() => _importing = true);
    final api = AdminApi(ref.read(clientProvider));
    final notes = <String>[];
    var added = 0;
    try {
      final (emails, bad) = parseGroupCsv(
        utf8.decode(await picked.first.readAsBytes()),
      );
      for (final row in bad) {
        notes.add('Row ${row + 1}: not "Name,Email"');
      }
      final have = {for (final m in _members) '${m['email']}'.toLowerCase()};
      final ids = <String>[];
      for (final email in emails) {
        if (have.contains(email)) continue;
        final found = (await api.users(query: email))
            .where((u) => u.email.toLowerCase() == email)
            .firstOrNull;
        if (found == null) {
          notes.add('$email: no such user');
        } else {
          ids.add(found.id);
        }
      }
      if (ids.isNotEmpty) {
        await ref
            .read(clientProvider)
            .send('POST', '$_base/users/add', body: {'user_ids': ids});
        added = ids.length;
      }
      await _loadMembers();
    } catch (e) {
      notes.add('$e');
    }
    if (!mounted) return;
    setState(() => _importing = false);
    _say(
      context,
      [
        added == 0 ? 'No one new added' : 'Added $added',
        ...notes.take(3),
        if (notes.length > 3) '…and ${notes.length - 3} more',
      ].join('\n'),
    );
  }

  Future<void> _csvTemplate() async {
    await FilePicker.saveFile(
      fileName: 'group-import.csv',
      bytes: utf8.encode('Name,Email\n'),
    );
  }

  Future<void> _pickParent() async {
    final skip = groupAndBelow(widget.groups, _id);
    final picked = await showModalBottomSheet<(String?,)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const T('No parent'),
              trailing: _parent == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(sheet, (null,)),
            ),
            for (final (g, depth) in groupTree(widget.groups))
              if (!skip.contains('${g['id']}'))
                ListTile(
                  contentPadding: EdgeInsetsDirectional.only(
                    start: 16.0 + 20 * depth.clamp(0, 6),
                    end: 16,
                  ),
                  title: Text('${g['name']}'),
                  trailing: _parent == g['id'] ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(sheet, ('${g['id']}',)),
                ),
          ],
        ),
      ),
    );
    if (picked == null || picked.$1 == _parent) return;
    setState(() => _parent = picked.$1);
    _changed();
  }

  Future<void> _pickDefaultModels() async {
    final models = await ref.read(modelsProvider.future);
    if (!mounted) return;
    final chosen = {..._defaultModels};
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, set) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final m in models)
                      CheckboxListTile(
                        value: chosen.contains(m.id),
                        title: Text(m.name),
                        onChanged: (on) => set(
                          () => on == true
                              ? chosen.add(m.id)
                              : chosen.remove(m.id),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: () => Navigator.pop(sheet, true),
                  child: const T('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    setState(() => _config['default_models'] = [...chosen]);
    _changed();
  }

  Future<void> _removeMember(String userId) async {
    try {
      await ref
          .read(clientProvider)
          .send(
            'POST',
            '$_base/users/remove',
            body: {
              'user_ids': [userId],
            },
          );
      await _loadMembers();
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${_name.text}?'),
        content: const T(
          'Its members lose what it gives them. They keep their accounts.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const T('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(clientProvider).send('DELETE', '$_base/delete');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  void _changed() {
    if (!_dirty) setState(() => _dirty = true);
  }

  String _defaultModelsText() {
    final mine = _defaultModels;
    if (mine.isNotEmpty) return mine.join(', ');
    final eff = (_preview?['default_models'] as Map?)?['effective'] as List?;
    final from = (_preview?['default_models'] as Map?)?['source_group_id'];
    final source = from == null
        ? 'Global defaults'
        : '${widget.groups.where((g) => g['id'] == from).firstOrNull?['name'] ?? 'Parent group'}';
    return 'Inherit · $source${eff == null || eff.isEmpty ? '' : ': ${eff.join(', ')}'}';
  }

  /// What members can reach through this group, as the web's Preview tab.
  List<Widget> _previewSection(TextStyle? heading, Color muted) {
    final p = _preview!;
    Widget part(String title, String key, String none) {
      final part = (p[key] as Map?) ?? const {};
      final items = [
        for (final i in part['items'] as List? ?? const [])
          if (i is Map) '${i['name'] ?? i['id']}',
      ];
      final total = part['total'] as int? ?? items.length;
      return ListTile(
        dense: true,
        title: Text(title),
        subtitle: Text(
          items.isEmpty
              ? none
              : [
                  items.join(', '),
                  if (total > items.length) '${items.length} of $total',
                ].join(' · '),
          style: TextStyle(color: muted),
        ),
      );
    }

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: T('Preview', style: heading),
      ),
      if (_dirty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: T('Save to see changes here.', style: TextStyle(color: muted)),
        ),
      part('Models', 'models', 'No models accessible'),
      part('Knowledge', 'knowledge', 'No knowledge bases accessible'),
      part('Tools', 'tools', 'No tools accessible'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Section names in the accent colour, as on every settings page.
    final heading = Theme.of(context).textTheme.titleSmall
        ?.copyWith(color: Theme.of(context).colorScheme.primary);
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const T('Group'),
        actions: [
          IconButton(
            tooltip: tr('Delete group'),
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _dirty ? _save : null,
              child: const T('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _name,
              decoration: InputDecoration(labelText: tr('Name')),
              onChanged: (_) => _changed(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _about,
              decoration: InputDecoration(labelText: tr('Description')),
              onChanged: (_) => _changed(),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.account_tree_outlined),
            title: const T('Parent group'),
            subtitle: Text(
              _parent == null
                  ? 'No parent'
                  : '${widget.groups.where((g) => g['id'] == _parent).firstOrNull?['name'] ?? _parent}',
            ),
            onTap: _pickParent,
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const T('Default models'),
            subtitle: Text(
              _defaultModelsText(),
              style: TextStyle(color: muted),
            ),
            trailing: _defaultModels.isEmpty
                ? null
                : TextButton(
                    onPressed: () {
                      setState(() => _config['default_models'] = <String>[]);
                      _changed();
                    },
                    child: const T('Inherit'),
                  ),
            onTap: _pickDefaultModels,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: DropdownButtonFormField<String>(
              initialValue: '${_config['share'] ?? 'members'}',
              decoration: InputDecoration(
                labelText: tr('Who can share to this group'),
              ),
              items: [
                for (final o in groupShareOptions.entries)
                  DropdownMenuItem(value: o.key, child: Text(o.value)),
              ],
              onChanged: (v) {
                _config['share'] = switch (v) {
                  'true' => true,
                  'false' => false,
                  _ => v,
                };
                _changed();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 0, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _showInherited
                        ? 'Inherited members (${_inherited.length})'
                        : 'Members (${_members.length})',
                    style: heading,
                  ),
                ),
                if (_importing)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                TextButton.icon(
                  onPressed: _addMember,
                  icon: const Icon(Icons.person_add_alt),
                  label: const T('Add'),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) => switch (v) {
                    'direct' => setState(() => _showInherited = false),
                    'inherited' => setState(() => _showInherited = true),
                    'csv' => _importCsv(),
                    'template' => _csvTemplate(),
                    _ => null,
                  },
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(
                      value: 'direct',
                      checked: !_showInherited,
                      child: const T('Direct'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'inherited',
                      checked: _showInherited,
                      child: const T('Inherited'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'csv', child: T('Import CSV')),
                    const PopupMenuItem(
                      value: 'template',
                      child: T('Download CSV Template'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_showInherited && _inherited.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: T(
                'No one is in this group through a subgroup.',
                style: TextStyle(color: muted),
              ),
            ),
          for (final m in _showInherited ? _inherited : _members)
            ListTile(
              dense: true,
              title: Text('${m['name'] ?? ''}'),
              subtitle: Text('${m['email'] ?? ''}'),
              trailing: _showInherited
                  ? null
                  : IconButton(
                      tooltip: tr('Remove'),
                      onPressed: () => _removeMember('${m['id']}'),
                      icon: const Icon(Icons.person_remove_outlined),
                    ),
            ),
          if (_preview != null) ..._previewSection(heading, muted),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
            child: T('Permissions', style: heading),
          ),
          if (_perms == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            PermissionsEditor(permissions: _perms!, onChanged: _changed),
        ],
      ),
    );
  }
}

class _UserPicker extends StatefulWidget {
  const _UserPicker({required this.api, required this.skip});
  final AdminApi api;
  final Set<String> skip;

  @override
  State<_UserPicker> createState() => _UserPickerState();
}

class _UserPickerState extends State<_UserPicker> {
  List<AdminUser> _found = const [];
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  Future<void> _search(String q) async {
    final ask = ++_asked;
    try {
      final found = await widget.api.users(query: q);
      if (mounted && ask == _asked) {
        setState(
          () => _found = [
            for (final u in found)
              if (!widget.skip.contains(u.id)) u,
          ],
        );
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
    child: SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: tr('Add someone'),
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: _search,
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final u in _found)
                  ListTile(
                    title: Text(u.name),
                    subtitle: Text(u.email),
                    onTap: () => Navigator.pop(context, u),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
