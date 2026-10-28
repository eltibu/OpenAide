import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/advanced_params.dart';
import '../chat/chat_controller.dart';
import 'knowledge_screen.dart' show knowledgeListProvider;
import 'access_editor.dart' show ItemMenu, readGrants, writeGrants;
import 'models_api.dart';
import '../chat/model_pins.dart'
    show modelLink, pinnedModelsProvider, togglePinnedModel;

final modelsApiProvider = Provider<ModelsApi>(
  (ref) => ModelsApi(ref.watch(clientProvider)),
);

final workspaceModelsProvider = FutureProvider<List<WorkspaceModel>>(
  (ref) => ref.watch(modelsApiProvider).list(),
);

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// The workspace's own models.
class ModelsScreen extends ConsumerWidget {
  const ModelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(workspaceModelsProvider);
    final muted = context.nexus.muted;
    Future<void> edit([WorkspaceModel? m]) async {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => ModelEditor(model: m)),
      );
      ref.invalidate(workspaceModelsProvider);
      ref.invalidate(modelsProvider);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Models')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New model',
        onPressed: edit,
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(workspaceModelsProvider.future),
        child: list.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load models.\n$e'),
              ),
            ],
          ),
          data: (items) => ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No custom models yet. Tap + to give a model its own '
                    'instructions, knowledge and tools.',
                    style: TextStyle(color: muted),
                  ),
                ),
              for (final m in items)
                ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.auto_awesome_outlined),
                  ),
                  title: Text(m.name),
                  subtitle: Text(
                    m.description.isNotEmpty
                        ? m.description
                        : (m.baseModelId ?? m.id),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: muted),
                  ),
                  onTap: () => edit(m),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _WorkspaceModelMenu(model: m),
                      Switch(
                        value: m.active,
                        onChanged: m.writable
                            ? (_) async {
                                try {
                                  await ref
                                      .read(modelsApiProvider)
                                      .toggle(m.id);
                                } catch (e) {
                                  if (context.mounted) _say(context, '$e');
                                }
                                ref.invalidate(workspaceModelsProvider);
                                ref.invalidate(modelsProvider);
                              }
                            : null,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class ModelEditor extends ConsumerStatefulWidget {
  const ModelEditor({
    super.key,
    this.model,
    this.copyOf,
    this.connectionModel = false,
    this.saved = true,
  });
  final WorkspaceModel? model;

  /// Starts a new model as a copy of this one.
  final WorkspaceModel? copyOf;

  /// Admin: [model] is a model from a connection, changed in place (no base
  /// model). [saved] says whether the server already keeps changes for it.
  final bool connectionModel;
  final bool saved;

  @override
  ConsumerState<ModelEditor> createState() => _ModelEditorState();
}

class _ModelEditorState extends ConsumerState<ModelEditor> {
  WorkspaceModel? _m;
  bool _loading = true;
  bool _busy = false;
  final _name = TextEditingController();
  final _id = TextEditingController();
  final _description = TextEditingController();
  final _system = TextEditingController();
  String? _base;
  Map<String, dynamic> _caps = {};
  Set<String> _knowledge = {};
  Set<String> _tools = {};
  Set<String> _skills = {};
  Map<String, dynamic> _params = {};

  /// The model's starter prompts; null uses the server's defaults.
  List<Map<String, dynamic>>? _suggestions;
  bool _idEdited = false;

  bool get _isNew => widget.model == null;
  bool get _connection => widget.connectionModel;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_isNew) {
      try {
        _m = await ref.read(modelsApiProvider).get(widget.model!.id);
      } catch (_) {
        _m = widget.model;
      }
      final m = _m!;
      _name.text = m.name;
      _id.text = m.id;
      _description.text = m.description;
      _system.text = m.system;
      _base = m.baseModelId;
      _caps = {...m.capabilities};
      _knowledge = {for (final k in m.knowledge) k.$1};
      _tools = m.ids('toolIds').toSet();
      _skills = m.ids('skillIds').toSet();
      _params = {...m.params}..remove('system');
      _suggestions = readSuggestions(m.meta['suggestion_prompts']);
    } else if (widget.copyOf case final c?) {
      _name.text = '${c.name} (copy)';
      _id.text = modelIdFrom(_name.text);
      _description.text = c.description;
      _system.text = c.system;
      _base = c.baseModelId ?? c.id;
      _caps = {...c.capabilities};
      _knowledge = {for (final k in c.knowledge) k.$1};
      _tools = c.ids('toolIds').toSet();
      _skills = c.ids('skillIds').toSet();
      _params = {...c.params}..remove('system');
      _suggestions = readSuggestions(c.meta['suggestion_prompts']);
    } else {
      // A new model starts with the abilities the web turns on by default.
      _caps = {for (final k in defaultModelCapabilities) k: true};
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final id = _isNew ? modelIdFrom(_id.text.trim()) : _m!.id;
    if (name.isEmpty || id.isEmpty || (_base == null && !_connection)) {
      _say(context, 'Name, id and base model are needed');
      return;
    }
    final kbs = ref.read(knowledgeListProvider).value ?? const [];
    final old = _m?.json ?? <String, dynamic>{};
    final source = _m ?? widget.copyOf;
    final meta = {...?source?.meta};
    final params = {..._params};
    meta['description'] = _description.text.trim();
    meta['capabilities'] = _caps;
    meta['toolIds'] = _tools.toList();
    meta['skillIds'] = _skills.toList();
    meta['knowledge'] = [
      for (final id in _knowledge)
        () {
          final k = kbs.where((k) => k.id == id).firstOrNull;
          // Keep how the server stored ones the app can't list.
          final kept = (source?.meta['knowledge'] as List? ?? const [])
              .whereType<Map>()
              .where((m) => m['id'] == id)
              .firstOrNull;
          return kept ??
              {
                'id': id,
                'name': k?.name ?? id,
                'description': k?.description ?? '',
                'type': 'collection',
              };
        }(),
    ];
    meta['suggestion_prompts'] = _suggestions;
    meta['profile_image_url'] ??= '/static/favicon.png';
    final system = _system.text.trim();
    if (system.isEmpty) {
      params.remove('system');
    } else {
      params['system'] = system;
    }
    setState(() => _busy = true);
    try {
      final create = _isNew || (_connection && !widget.saved);
      await ref.read(modelsApiProvider).save({
        ...old,
        'id': id,
        'name': name,
        'base_model_id': _connection ? null : _base,
        'meta': meta,
        'params': params,
        'is_active': _m?.active ?? true,
        if (_connection && create) 'access_grants': publicModelGrants,
      }, create: create);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        _say(context, '$e');
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(_connection ? 'Reset ${_m!.name}?' : 'Delete ${_m!.name}?'),
        content: Text(
          _connection
              ? 'Your changes to it are removed and it goes back to how its '
                    'connection sends it.'
              : 'This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(_connection ? 'Reset' : 'Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(modelsApiProvider).delete(_m!.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  Widget _chips(String title, List<(String, String)> all, Set<String> picked) {
    if (all.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: context.nexus.muted)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final (id, name) in all)
                FilterChip(
                  label: Text(name),
                  selected: picked.contains(id),
                  onSelected: (on) =>
                      setState(() => on ? picked.add(id) : picked.remove(id)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final models = ref.watch(modelsProvider).value ?? const [];
    final kbs = ref.watch(knowledgeListProvider).value ?? const [];
    final tools = ref.watch(toolsProvider).value ?? const [];
    final skills = ref.watch(skillsProvider).value ?? const [];
    final bases = [
      for (final m in models)
        if (m.id != _m?.id) m,
    ];
    final writable = _isNew || (_m?.writable ?? true);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New model' : 'Edit model'),
        actions: [
          if (!_isNew && (!_connection || widget.saved) && _m != null)
            ItemMenu(
              kind: 'model',
              id: _m!.id,
              name: _m!.name,
              onRestored: () => Navigator.pop(context),
            ),
          if (!_isNew && !_connection)
            IconButton(
              tooltip: 'Clone',
              onPressed: _loading
                  ? null
                  : () => Navigator.pushReplacement(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ModelEditor(copyOf: _m),
                      ),
                    ),
              icon: const Icon(Icons.copy_all_outlined),
            ),
          if (!_isNew && writable && (!_connection || widget.saved))
            IconButton(
              tooltip: _connection ? 'Reset to defaults' : 'Delete',
              onPressed: _busy || _loading ? null : _delete,
              icon: Icon(
                _connection ? Icons.restart_alt : Icons.delete_outline,
              ),
            ),
          if (writable)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: _busy || _loading ? null : _save,
                child: Text(_isNew ? 'Create' : 'Save'),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      TextField(
                        controller: _name,
                        autofocus: _isNew,
                        onChanged: (v) {
                          if (_isNew && !_idEdited) _id.text = modelIdFrom(v);
                        },
                        decoration: const InputDecoration(labelText: 'Name'),
                      ),
                      TextField(
                        controller: _id,
                        enabled: _isNew,
                        onChanged: (_) => _idEdited = true,
                        decoration: const InputDecoration(labelText: 'Id'),
                      ),
                      if (!_connection)
                        DropdownButtonFormField<String>(
                          initialValue: bases.any((m) => m.id == _base)
                              ? _base
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Base model',
                          ),
                          items: [
                            for (final m in bases)
                              DropdownMenuItem(
                                value: m.id,
                                child: Text(
                                  m.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(() => _base = v),
                        ),
                      TextField(
                        controller: _description,
                        maxLines: null,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _system,
                        minLines: 4,
                        maxLines: null,
                        decoration: const InputDecoration(
                          labelText: 'System prompt',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
                _chips('Knowledge', [
                  for (final k in kbs) (k.id, k.name),
                  for (final (id, name)
                      in _m?.knowledge ?? const <(String, String)>[])
                    if (!kbs.any((k) => k.id == id)) (id, name),
                ], _knowledge),
                _chips('Tools', [
                  for (final t in tools) (t.id, t.name),
                ], _tools),
                _chips('Skills', [
                  for (final s in skills) (s.id, s.name),
                ], _skills),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Text(
                    'Abilities',
                    style: TextStyle(color: context.nexus.muted),
                  ),
                ),
                for (final c in modelCapabilities.entries)
                  SwitchListTile(
                    dense: true,
                    title: Text(c.value),
                    value: _caps[c.key] == true,
                    onChanged: (on) => setState(() => _caps[c.key] = on),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Model parameters'),
                    subtitle: Text(
                      _params.isEmpty
                          ? 'All on default'
                          : '${_params.length} set',
                    ),
                    children: [
                      AdvancedParamsEditor(
                        params: _params,
                        onChanged: (k, v) => setState(
                          () => v == null ? _params.remove(k) : _params[k] = v,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: PromptSuggestionsEditor(
                    value: _suggestions,
                    onChanged: (v) => setState(() => _suggestions = v),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Keep in sidebar, copy link and hide or show, as the web's model menu.
class _WorkspaceModelMenu extends ConsumerWidget {
  const _WorkspaceModelMenu({required this.model});
  final WorkspaceModel model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned = ref.watch(pinnedModelsProvider).contains(model.id);
    final hidden = model.meta['hidden'] == true;
    return PopupMenuButton<String>(
      tooltip: 'More',
      onSelected: (v) async {
        try {
          switch (v) {
            case 'pin':
              await togglePinnedModel(ref, model.id);
            case 'link':
              await Clipboard.setData(
                ClipboardData(
                  text: modelLink(
                    ref.read(sessionProvider).value?.serverUrl ?? '',
                    model.id,
                  ),
                ),
              );
              if (context.mounted) _say(context, 'Link copied');
            case 'hide':
              await ref.read(modelsApiProvider).save({
                ...model.json,
                'meta': {...model.meta, 'hidden': !hidden},
                if (model.json['access_grants'] is List)
                  'access_grants': writeGrants(
                    readGrants(model.json['access_grants']),
                  ),
              }, create: false);
              ref.invalidate(workspaceModelsProvider);
              ref.invalidate(modelsProvider);
          }
        } catch (e) {
          if (context.mounted) _say(context, '$e');
        }
      },
      itemBuilder: (_) => [
        if (model.writable)
          PopupMenuItem(
            value: 'hide',
            child: Text(hidden ? 'Show Model' : 'Hide Model'),
          ),
        PopupMenuItem(
          value: 'pin',
          child: Text(pinned ? 'Hide from Sidebar' : 'Keep in Sidebar'),
        ),
        const PopupMenuItem(value: 'link', child: Text('Copy Link')),
      ],
    );
  }
}

/// Starter prompts as the server keeps them: `{title: [line 1, line 2],
/// content}`.
List<Map<String, dynamic>>? readSuggestions(Object? raw) => raw is! List
    ? null
    : [
        for (final s in raw.whereType<Map>())
          {
            'title': switch (s['title']) {
              final String t => [t, ''],
              final List t => [
                for (final p in t) '$p',
                '',
                '',
              ].take(2).toList(),
              _ => ['', ''],
            },
            'content': '${s['content'] ?? ''}',
          },
      ];

/// The model's prompt suggestions: the server's defaults, or its own list
/// to add to and remove from.
class PromptSuggestionsEditor extends StatelessWidget {
  const PromptSuggestionsEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final List<Map<String, dynamic>>? value;
  final ValueChanged<List<Map<String, dynamic>>?> onChanged;

  Future<Map<String, dynamic>?> _edit(
    BuildContext context, [
    Map<String, dynamic>? s,
  ]) async {
    final title = (s?['title'] as List?) ?? const ['', ''];
    final t1 = TextEditingController(text: '${title[0]}');
    final t2 = TextEditingController(text: '${title[1]}');
    final content = TextEditingController(text: '${s?['content'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(s == null ? 'Add prompt suggestion' : 'Prompt suggestion'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: t1,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            TextField(
              controller: t2,
              decoration: const InputDecoration(labelText: 'Subtitle'),
            ),
            TextField(
              controller: content,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(labelText: 'Prompt'),
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
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok != true || content.text.trim().isEmpty) return null;
    return {
      'title': [t1.text.trim(), t2.text.trim()],
      'content': content.text.trim(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final list = value;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('Prompt suggestions'),
      subtitle: Text(list == null ? 'Default' : 'Custom · ${list.length}'),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Use default'),
          subtitle: const Text("The server's starter prompts"),
          value: list == null,
          onChanged: (on) => onChanged(on ? null : []),
        ),
        if (list != null) ...[
          for (final (i, s) in list.indexed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                [
                  for (final t in s['title'] as List)
                    if ('$t'.isNotEmpty) '$t',
                ].join(' · ').ifEmpty('${s['content']}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${s['content']}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () async {
                final changed = await _edit(context, s);
                if (changed != null) {
                  onChanged([...list]..[i] = changed);
                }
              },
              trailing: IconButton(
                tooltip: 'Remove prompt suggestion',
                icon: const Icon(Icons.close),
                onPressed: () => onChanged([...list]..removeAt(i)),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add prompt suggestion'),
              onPressed: () async {
                final added = await _edit(context);
                if (added != null) onChanged([...list, added]);
              },
            ),
          ),
        ],
      ],
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
