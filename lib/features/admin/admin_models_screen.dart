/// Admin > Models: every model the connections bring in, switched on or
/// off, hidden, renamed and set up for everyone, plus defaults, the order
/// of the list, import and export.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart' show modelsProvider;
import '../workspace/models_api.dart';
import 'manage_ollama.dart';
import '../workspace/models_screen.dart'
    show ModelEditor, modelsApiProvider, workspaceModelsProvider;

/// One connection model as the admin page shows it: what the server lists
/// now, and the changes saved for it (if any).
class AdminModel {
  AdminModel({required this.id, required this.name, this.live, this.record});

  final String id;
  final String name;

  /// As /api/models lists it; null when it's switched off.
  final Map<String, dynamic>? live;

  /// The saved changes for it; null when it's as the connection sends it.
  final WorkspaceModel? record;

  bool get active => record?.active ?? true;
  bool get hidden => record?.meta['hidden'] == true;
  String get ownedBy => '${live?['owned_by'] ?? ''}';
  String get description =>
      record?.description ??
      '${((live?['info'] as Map?)?['meta'] as Map?)?['description'] ?? ''}';

  /// What the editor starts from when nothing is saved for it yet.
  WorkspaceModel draft(Map<String, dynamic> defaults) {
    if (record case final r?) return r;
    final caps = (defaults['capabilities'] as Map?)?.cast<String, dynamic>();
    return WorkspaceModel({
      'id': id,
      'name': name,
      'base_model_id': null,
      'meta': {
        'profile_image_url': '/static/favicon.png',
        'description': '',
        'capabilities':
            caps ?? {for (final k in defaultModelCapabilities) k: true},
      },
      'params': <String, dynamic>{},
      'is_active': true,
    });
  }
}

/// Puts the server's lists together the way the web's admin page does:
/// connection models in their saved order, then switched-off ones.
List<AdminModel> mergeAdminModels(
  List<Map<String, dynamic>> live,
  List<WorkspaceModel> records,
) {
  final byId = {for (final r in records) r.id: r};
  final out = <AdminModel>[];
  final seen = <String>{};
  for (final m in live) {
    final info = m['info'];
    // Workspace models (built on another model) have their own page.
    if (info is Map && info['base_model_id'] != null) continue;
    final id = '${m['id']}';
    if (!seen.add(id)) continue;
    out.add(
      AdminModel(id: id, name: '${m['name'] ?? id}', live: m, record: byId[id]),
    );
  }
  for (final r in records) {
    if (seen.add(r.id)) {
      out.add(AdminModel(id: r.id, name: r.name, record: r));
    }
  }
  return out;
}

List<String> _csv(Object? v) => [
  for (final s in '${v ?? ''}'.split(','))
    if (s.trim().isNotEmpty) s.trim(),
];

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

class AdminModelsScreen extends ConsumerStatefulWidget {
  const AdminModelsScreen({super.key});

  @override
  ConsumerState<AdminModelsScreen> createState() => _AdminModelsScreenState();
}

class _AdminModelsScreenState extends ConsumerState<AdminModelsScreen> {
  List<AdminModel>? _models;
  Map<String, dynamic> _config = {};
  Object? _error;
  String _query = '';
  bool _busy = false;

  /// Set while dragging the list into a new order.
  List<AdminModel>? _ordering;

  ModelsApi get _api => ref.read(modelsApiProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = ref.read(clientProvider);
      final res = await client.send(
        'GET',
        '/api/models',
        query: {'refresh': 'true'},
      );
      final live = [
        for (final m
            in (res is Map ? res['data'] as List? : res as List?) ?? const [])
          if (m is Map) m.cast<String, dynamic>(),
      ];
      final records = await _api.baseRecords();
      _config = await _api.config();
      _models = mergeAdminModels(live, records);
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  /// Reloads here and everywhere models are listed.
  Future<void> _changed() async {
    ref.invalidate(modelsProvider);
    ref.invalidate(workspaceModelsProvider);
    await _load();
  }

  Future<void> _run(Future<void> Function() job, [String? done]) async {
    setState(() => _busy = true);
    try {
      await job();
      if (done != null && mounted) _say(context, done);
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    await _changed();
    if (mounted) setState(() => _busy = false);
  }

  Map<String, dynamic> get _defaults =>
      (_config['DEFAULT_MODEL_METADATA'] as Map?)?.cast<String, dynamic>() ??
      const {};

  /// Saves a switch or the hidden flag, keeping the model public when it
  /// gets its first saved change.
  Future<void> _write(AdminModel m, {bool? active, bool? hidden}) async {
    final r = m.record;
    if (r == null) {
      if ((active ?? true) && hidden != true) return;
      final json = {...m.draft(_defaults).json};
      json['is_active'] = active ?? true;
      if (hidden != null) {
        json['meta'] = {...(json['meta'] as Map), 'hidden': hidden};
      }
      json['access_grants'] = publicModelGrants;
      await _api.save(json, create: true);
      return;
    }
    if (active != null && active != r.active) await _api.toggle(m.id);
    if (hidden != null && hidden != m.hidden) {
      await _api.save({
        ...r.json,
        'meta': {...r.meta, 'hidden': hidden},
      }, create: false);
    }
  }

  Future<void> _all({bool? active, bool? hidden}) async {
    final list = _models ?? const [];
    await _run(() async {
      for (final m in list) {
        await _write(m, active: active, hidden: hidden);
      }
    }, 'Done');
  }

  Future<void> _saveConfig(Map<String, dynamic> changes) => _run(() async {
    await _api.saveConfig({..._config, ...changes});
  });

  Future<void> _toggleIn(String key, String id) {
    final ids = _csv(_config[key]);
    ids.contains(id) ? ids.remove(id) : ids.add(id);
    return _saveConfig({key: ids.join(',')});
  }

  Future<void> _edit(AdminModel m) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ModelEditor(
          model: m.draft(_defaults),
          connectionModel: true,
          saved: m.record != null,
        ),
      ),
    );
    await _changed();
  }

  Future<void> _clone(AdminModel m) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ModelEditor(copyOf: m.draft(_defaults)),
      ),
    );
    await _changed();
  }

  Future<void> _export([AdminModel? m]) async {
    try {
      // The server's export only covers workspace models, so these are
      // written out as their saved records, which import takes back.
      final data = [
        for (final x in m == null ? _models ?? const <AdminModel>[] : [m])
          if (x.record case final r?) r.json,
      ];
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final name = m == null
          ? 'models-export-$stamp.json'
          : '${modelIdFrom(m.id)}-$stamp.json';
      final saved = await FilePicker.saveFile(
        fileName: name,
        bytes: Uint8List.fromList(utf8.encode(jsonEncode(data))),
      );
      if (saved != null && mounted) _say(context, 'Saved $name');
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    final f = picked.first;
    List<dynamic> models;
    try {
      final data = jsonDecode(utf8.decode(await f.readAsBytes()));
      models = data is List ? data : [data];
    } catch (_) {
      if (mounted) _say(context, '${f.name} isn\'t a models file');
      return;
    }
    await _run(
      () => _api.import(models),
      'Imported ${models.length} model${models.length == 1 ? '' : 's'}',
    );
  }

  Future<void> _resetOrder() => _saveConfig({'MODEL_ORDER_LIST': <String>[]});

  Future<void> _saveOrder() async {
    final list = _ordering!;
    setState(() => _ordering = null);
    await _saveConfig({
      'MODEL_ORDER_LIST': [for (final m in list) m.id],
    });
  }

  Widget _tile(AdminModel m, {required bool def, required bool pinned}) {
    final muted = context.nexus.muted;
    final tags = [
      m.id,
      if (m.ownedBy.isNotEmpty) m.ownedBy,
      if (m.hidden) 'hidden',
      if (m.live == null && m.active) 'offline',
    ];
    return ListTile(
      key: ValueKey(m.id),
      leading: CircleAvatar(
        child: Text(m.name.isEmpty ? '?' : m.name[0].toUpperCase()),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              m.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: m.active ? null : muted),
            ),
          ),
          if (def) ...[
            const SizedBox(width: 4),
            Icon(Icons.star, size: 16, color: NexusColors.accent),
          ],
          if (pinned) ...[
            const SizedBox(width: 4),
            Icon(Icons.push_pin, size: 14, color: muted),
          ],
        ],
      ),
      subtitle: Text(
        tags.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: muted),
      ),
      onTap: _busy ? null : () => _edit(m),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: m.active,
            onChanged: _busy ? null : (on) => _run(() => _write(m, active: on)),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            enabled: !_busy,
            onSelected: (v) => switch (v) {
              'edit' => _edit(m),
              'hide' => _run(() => _write(m, hidden: !m.hidden)),
              'default' => _toggleIn('DEFAULT_MODELS', m.id),
              'pin' => _toggleIn('DEFAULT_PINNED_MODELS', m.id),
              'copy' => Clipboard.setData(
                ClipboardData(text: m.id),
              ).then((_) => mounted ? _say(context, 'Copied ${m.id}') : null),
              'clone' => _clone(m),
              'export' => _export(m),
              _ => null,
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(
                value: 'hide',
                child: Text(
                  m.hidden ? 'Show in model list' : 'Hide from model list',
                ),
              ),
              PopupMenuItem(
                value: 'default',
                child: Text(
                  def ? 'Remove as default model' : 'Make a default model',
                ),
              ),
              PopupMenuItem(
                value: 'pin',
                child: Text(pinned ? 'Unpin for everyone' : 'Pin for everyone'),
              ),
              const PopupMenuItem(value: 'copy', child: Text('Copy id')),
              const PopupMenuItem(value: 'clone', child: Text('Clone')),
              if (m.record != null)
                const PopupMenuItem(value: 'export', child: Text('Export')),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _models;
    final muted = context.nexus.muted;
    final defaults = _csv(_config['DEFAULT_MODELS']);
    final pinned = _csv(_config['DEFAULT_PINNED_MODELS']);
    String nameOf(String id) =>
        list?.where((m) => m.id == id).firstOrNull?.name ?? id;
    final ordering = _ordering;
    return Scaffold(
      appBar: AppBar(
        title: Text(ordering == null ? 'Models' : 'Drag to reorder'),
        actions: ordering != null
            ? [
                TextButton(
                  onPressed: () => setState(() => _ordering = null),
                  child: const Text('Cancel'),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton(
                    onPressed: _saveOrder,
                    child: const Text('Save'),
                  ),
                ),
              ]
            : [
                IconButton(
                  tooltip: 'Manage Ollama models',
                  icon: const Icon(Icons.download_for_offline_outlined),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const ManageOllamaScreen(),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Reorder',
                  onPressed: list == null || _busy
                      ? null
                      : () => setState(() => _ordering = [...list]),
                  icon: const Icon(Icons.swap_vert),
                ),
                PopupMenuButton<String>(
                  enabled: list != null && !_busy,
                  onSelected: (v) => switch (v) {
                    'on' => _all(active: true),
                    'off' => _all(active: false),
                    'show' => _all(hidden: false),
                    'hide' => _all(hidden: true),
                    'import' => _import(),
                    'export' => _export(),
                    'order' => _resetOrder(),
                    _ => null,
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'on', child: Text('Enable all')),
                    PopupMenuItem(value: 'off', child: Text('Disable all')),
                    PopupMenuItem(value: 'show', child: Text('Show all')),
                    PopupMenuItem(value: 'hide', child: Text('Hide all')),
                    PopupMenuDivider(),
                    PopupMenuItem(value: 'import', child: Text('Import')),
                    PopupMenuItem(value: 'export', child: Text('Export all')),
                    PopupMenuItem(
                      value: 'order',
                      child: Text('Reset order (by name)'),
                    ),
                  ],
                ),
              ],
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: list == null
          ? Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Couldn\'t load models.\n$_error'),
                    )
                  : const CircularProgressIndicator(),
            )
          : ordering != null
          ? ReorderableListView(
              onReorderItem: (from, to) =>
                  setState(() => ordering.insert(to, ordering.removeAt(from))),
              children: [
                for (final m in ordering)
                  ListTile(
                    key: ValueKey(m.id),
                    leading: const Icon(Icons.drag_handle),
                    title: Text(m.name),
                    subtitle: Text(m.id, style: TextStyle(color: muted)),
                  ),
              ],
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 40),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Search models',
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Default: ${defaults.isEmpty ? 'none' : defaults.map(nameOf).join(', ')}'
                      '\nPinned for everyone: ${pinned.isEmpty ? 'none' : pinned.map(nameOf).join(', ')}',
                      style: TextStyle(color: muted),
                    ),
                  ),
                  for (final m in list)
                    if (_query.isEmpty ||
                        '${m.name} ${m.id}'.toLowerCase().contains(
                          _query.toLowerCase(),
                        ))
                      _tile(
                        m,
                        def: defaults.contains(m.id),
                        pinned: pinned.contains(m.id),
                      ),
                ],
              ),
            ),
    );
  }
}
