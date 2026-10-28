/// Who can use or change a workspace item (model, prompt, tool, skill,
/// knowledge, note), as the web's Access control: private or public,
/// public editing, and groups or people who can read or write.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../channels/channel_manage.dart' show pickPerson;
import '../channels/channels_api.dart';
import 'version_history.dart';

/// A grant as the server takes it back (only these three fields).
typedef Grant = ({String type, String id, String permission});

List<Grant> readGrants(Object? raw) => [
  for (final g in raw as List? ?? const [])
    if (g is Map)
      (
        type: '${g['principal_type']}',
        id: '${g['principal_id']}',
        permission: '${g['permission'] ?? 'read'}',
      ),
];

List<Map<String, String>> writeGrants(List<Grant> grants) => [
  for (final g in grants)
    {
      'principal_type': g.type,
      'principal_id': g.id,
      'permission': g.permission,
    },
];

bool _everyone(Grant g) => g.type == 'user' && g.id == '*';

/// Where each kind of item saves its access.
String accessPath(String kind, String id) => switch (kind) {
  'model' => '/api/v1/models/model/access/update',
  'prompt' => '/api/v1/prompts/id/$id/access/update',
  'tool' => '/api/v1/tools/id/$id/access/update',
  'skill' => '/api/v1/skills/id/$id/access/update',
  'knowledge' => '/api/v1/knowledge/$id/access/update',
  'note' => '/api/v1/notes/$id/access/update',
  'channel' => '/api/v1/channels/$id/access/update',
  'folder' => '/api/v1/folders/$id/access/update',
  _ => throw ArgumentError(kind),
};

/// Where each kind of item is read, with its grants.
String itemPath(String kind, String id) => switch (kind) {
  'model' => '/api/v1/models/model?id=${Uri.encodeQueryComponent(id)}',
  'prompt' => '/api/v1/prompts/id/$id',
  'tool' => '/api/v1/tools/id/$id',
  'skill' => '/api/v1/skills/id/$id',
  'knowledge' => '/api/v1/knowledge/$id',
  'note' => '/api/v1/notes/$id',
  'channel' => '/api/v1/channels/$id',
  'folder' => '/api/v1/folders/$id',
  _ => throw ArgumentError(kind),
};

/// Reads the item's current grants, then opens the editor, which saves.
Future<void> editAccess(
  BuildContext context,
  WidgetRef ref, {
  required String kind,
  required String id,
  required String name,
}) async {
  Object? grants;
  String? shareMode;
  try {
    final item = await ref.read(clientProvider).send('GET', itemPath(kind, id));
    grants = (item as Map?)?['access_grants'];
    shareMode = (item?['data'] as Map?)?['share_mode'] as String?;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Couldn\'t read access: $e')));
    }
    return;
  }
  if (!context.mounted) return;
  await Navigator.push<List<Grant>>(
    context,
    MaterialPageRoute(
      builder: (_) => AccessEditor(
        kind: kind,
        id: id,
        name: name,
        grants: readGrants(grants),
        shareMode: shareMode,
      ),
    ),
  );
}

/// Saves the item as the web's export file (a list with it in).
Future<void> exportItem(
  BuildContext context,
  WidgetRef ref, {
  required String kind,
  required String id,
  required String name,
}) async {
  try {
    final item = await ref.read(clientProvider).send('GET', itemPath(kind, id));
    final file =
        '$kind-${name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.json';
    final saved = await FilePicker.saveFile(
      fileName: file,
      bytes: Uint8List.fromList(utf8.encode(jsonEncode([item]))),
    );
    if (saved != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Saved $file')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// Access and Export for an item's editor, as the web's item menu.
class ItemMenu extends ConsumerWidget {
  const ItemMenu({
    super.key,
    required this.kind,
    required this.id,
    required this.name,
    this.onClone,
    this.onRestored,
    this.extra = const [],
  });

  final String kind, id, name;
  final VoidCallback? onClone;

  /// More entries for this kind: label and what it does.
  final List<(String, VoidCallback)> extra;

  /// After another version was put in use, so the editor reloads.
  final VoidCallback? onRestored;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PopupMenuButton<String>(
    tooltip: 'More',
    onSelected: (v) => switch (v) {
      'access' => editAccess(context, ref, kind: kind, id: id, name: name),
      'export' => exportItem(context, ref, kind: kind, id: id, name: name),
      'clone' => onClone?.call(),
      String v when v.startsWith('extra:') =>
        extra[int.parse(v.substring(6))].$2(),
      'history' => () async {
        final changed = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) =>
                VersionHistoryScreen(kind: kind, id: id, name: name),
          ),
        );
        if (changed == true) onRestored?.call();
      }(),
      _ => null,
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'access', child: Text('Access')),
      if (onClone != null)
        const PopupMenuItem(value: 'clone', child: Text('Clone')),
      const PopupMenuItem(value: 'export', child: Text('Export')),
      for (final (i, (label, _)) in extra.indexed)
        PopupMenuItem(value: 'extra:$i', child: Text(label)),
      const PopupMenuItem(value: 'history', child: Text('Version history')),
    ],
  );
}

class AccessEditor extends ConsumerStatefulWidget {
  const AccessEditor({
    super.key,
    required this.kind,
    required this.id,
    required this.name,
    required this.grants,
    this.shareMode,
  });

  final String kind, id, name;
  final List<Grant> grants;

  /// A folder's sharing mode: null (others can only clone its chats) or
  /// 'continue' (they can reply in them).
  final String? shareMode;

  @override
  ConsumerState<AccessEditor> createState() => _AccessEditorState();
}

class _AccessEditorState extends ConsumerState<AccessEditor> {
  late final List<Grant> _grants = [...widget.grants];
  late String? _shareMode = widget.shareMode;
  bool get _folder => widget.kind == 'folder';
  final Map<String, String> _names = {};
  List<Map<String, dynamic>> _groups = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  Future<void> _loadGroups() async {
    try {
      final res = await ref
          .read(clientProvider)
          .send('GET', '/api/v1/groups/', query: {'share': 'true'});
      _groups = [
        for (final g in res as List? ?? const [])
          if (g is Map) g.cast<String, dynamic>(),
      ];
      for (final g in _groups) {
        _names['group:${g['id']}'] = '${g['name']}';
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  bool get _public =>
      _grants.any((g) => _everyone(g) && g.permission == 'read');
  bool get _publicWrite =>
      _grants.any((g) => _everyone(g) && g.permission == 'write');

  void _setPublic(bool on) => setState(() {
    _grants.removeWhere(_everyone);
    if (on) _grants.add((type: 'user', id: '*', permission: 'read'));
  });

  void _setPublicWrite(bool on) => setState(() {
    _grants.removeWhere((g) => _everyone(g) && g.permission == 'write');
    if (on) _grants.add((type: 'user', id: '*', permission: 'write'));
  });

  /// Each principal shown once, with read or write.
  Map<(String, String), String> get _principals {
    final out = <(String, String), String>{};
    for (final g in _grants) {
      if (_everyone(g)) continue;
      final k = (g.type, g.id);
      if (out[k] != 'write') out[k] = g.permission;
    }
    return out;
  }

  void _set(String type, String id, String? permission) => setState(() {
    _grants.removeWhere((g) => g.type == type && g.id == id);
    if (permission == null) return;
    _grants.add((type: type, id: id, permission: 'read'));
    if (permission == 'write') {
      _grants.add((type: type, id: id, permission: 'write'));
    }
  });

  Future<void> _add() async {
    final which = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final g in _groups)
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: Text('${g['name']}'),
                onTap: () => Navigator.pop(c, 'group:${g['id']}'),
              ),
            ListTile(
              leading: const Icon(Icons.person_add_alt),
              title: const Text('A person…'),
              onTap: () => Navigator.pop(c, 'user'),
            ),
          ],
        ),
      ),
    );
    if (which == null || !mounted) return;
    if (which.startsWith('group:')) {
      _set('group', which.substring(6), 'read');
      return;
    }
    final person = await pickPerson(
      context,
      ChannelsApi(ref.read(clientProvider)),
      title: 'Give someone access',
    );
    if (person == null) return;
    _names['user:${person.id}'] = person.name;
    _set('user', person.id, 'read');
  }

  Future<void> _save() async {
    // An app's access is saved with the rest of the app.
    if (widget.kind == 'app') return Navigator.pop(context, _grants);
    setState(() => _busy = true);
    try {
      await ref
          .read(clientProvider)
          .send(
            'POST',
            accessPath(widget.kind, widget.id),
            body: {
              if (widget.kind == 'model') ...{
                'id': widget.id,
                'name': widget.name,
              },
              'access_grants': writeGrants(_grants),
              // Sent every time: the server resets it when left out.
              if (_folder) 'share_mode': _shareMode,
            },
          );
      if (mounted) Navigator.pop(context, _grants);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Not saved: $e')));
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: Text('Access: ${widget.name}'),
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
        children: [
          if (_folder)
            ListTile(
              title: const Text('Sharing mode'),
              subtitle: Wrap(
                spacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text('Clone only'),
                    selected: _shareMode == null,
                    onSelected: (_) => setState(() => _shareMode = null),
                  ),
                  ChoiceChip(
                    label: const Text('Allow replies'),
                    selected: _shareMode == 'continue',
                    onSelected: (_) => setState(() => _shareMode = 'continue'),
                  ),
                ],
              ),
            ),
          // Folders are shared with people and groups only, as on the web.
          if (!_folder)
            ListTile(
              title: const Text('Visibility'),
              subtitle: Wrap(
                spacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text('Private'),
                    selected: !_public,
                    onSelected: (_) => _setPublic(false),
                  ),
                  ChoiceChip(
                    label: const Text('Public'),
                    selected: _public,
                    onSelected: (_) => _setPublic(true),
                  ),
                ],
              ),
            ),
          if (_public && widget.kind != 'app')
            SwitchListTile(
              title: const Text('Allow public write access'),
              subtitle: const Text('Anyone can change it, not just use it'),
              value: _publicWrite,
              onChanged: _setPublicWrite,
            ),
          const Divider(),
          ListTile(
            title: const Text('Groups and people'),
            subtitle: Text(
              _principals.isEmpty
                  ? 'Only you${_public ? ' and everyone (to use)' : ''}.'
                  : 'Besides you',
              style: TextStyle(color: muted),
            ),
            trailing: TextButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('Add Access'),
            ),
          ),
          for (final e in _principals.entries)
            ListTile(
              leading: Icon(
                e.key.$1 == 'group'
                    ? Icons.groups_outlined
                    : Icons.person_outline,
              ),
              title: Text(_names['${e.key.$1}:${e.key.$2}'] ?? e.key.$2),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButton<String>(
                    value: e.value,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 'read', child: Text('Can use')),
                      DropdownMenuItem(value: 'write', child: Text('Can edit')),
                    ],
                    onChanged: (v) => _set(e.key.$1, e.key.$2, v),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close),
                    onPressed: () => _set(e.key.$1, e.key.$2, null),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
