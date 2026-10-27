/// Admin > Users > Groups and default permissions, as on the web: what
/// everyone may do, and groups that give their members more.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import 'admin_api.dart';
import 'config_editor.dart' show settingLabel;

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

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
      title: const Text('Default permissions'),
      actions: [
        PopupMenuButton<String>(
          onSelected: (_) =>
              _load('/api/v1/users/default/permissions/defaults', dirty: true),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'reset', child: Text('Reset to defaults')),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(
            onPressed: _dirty ? _save : null,
            child: const Text('Save'),
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
                child: Text(
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
class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final about = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('New group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: about,
              decoration: const InputDecoration(labelText: 'Description'),
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
            builder: (_) =>
                GroupEditor(group: (made as Map).cast<String, dynamic>()),
          ),
        );
        ref.invalidate(groupsProvider);
      }
    } catch (e) {
      if (context.mounted) _say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsProvider);
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(title: const Text('Groups')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context, ref),
        icon: const Icon(Icons.group_add_outlined),
        label: const Text('New group'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(groupsProvider.future),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('Default permissions'),
              subtitle: const Text('What everyone may do'),
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
                    child: Text(
                      'No groups yet.',
                      style: TextStyle(color: muted),
                    ),
                  ),
                for (final g in list)
                  ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.groups_outlined),
                    ),
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
                          builder: (_) => GroupEditor(group: g),
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
  const GroupEditor({super.key, required this.group});
  final Map<String, dynamic> group;

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
  bool _dirty = false;

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
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadMembers() async {
    final res = await ref
        .read(clientProvider)
        .send('GET', '$_base/members', query: {'membership': 'direct'});
    _members = [
      for (final u in (res as Map)['items'] as List? ?? const [])
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
              'data': widget.group['data'],
              'parent_group_id': widget.group['parent_group_id'],
            },
          );
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
        content: const Text(
          'Its members lose what it gives them. They keep their accounts.',
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

  @override
  Widget build(BuildContext context) {
    final heading = Theme.of(context).textTheme.titleSmall;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Group'),
        actions: [
          IconButton(
            tooltip: 'Delete group',
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _dirty ? _save : null,
              child: const Text('Save'),
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
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => _changed(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _about,
              decoration: const InputDecoration(labelText: 'Description'),
              onChanged: (_) => _changed(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text('Members (${_members.length})', style: heading),
                ),
                TextButton.icon(
                  onPressed: _addMember,
                  icon: const Icon(Icons.person_add_alt),
                  label: const Text('Add'),
                ),
              ],
            ),
          ),
          for (final m in _members)
            ListTile(
              dense: true,
              title: Text('${m['name'] ?? ''}'),
              subtitle: Text('${m['email'] ?? ''}'),
              trailing: IconButton(
                tooltip: 'Remove',
                onPressed: () => _removeMember('${m['id']}'),
                icon: const Icon(Icons.person_remove_outlined),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
            child: Text('Permissions', style: heading),
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
              decoration: const InputDecoration(
                hintText: 'Add someone',
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
