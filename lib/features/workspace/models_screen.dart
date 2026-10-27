import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import 'knowledge_screen.dart' show knowledgeListProvider;
import 'models_api.dart';

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
                  trailing: Switch(
                    value: m.active,
                    onChanged: m.writable
                        ? (_) async {
                            try {
                              await ref.read(modelsApiProvider).toggle(m.id);
                            } catch (e) {
                              if (context.mounted) _say(context, '$e');
                            }
                            ref.invalidate(workspaceModelsProvider);
                            ref.invalidate(modelsProvider);
                          }
                        : null,
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
  const ModelEditor({super.key, this.model});
  final WorkspaceModel? model;

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
  bool _idEdited = false;

  bool get _isNew => widget.model == null;

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
    } else {
      // A new model starts with the abilities the web turns on by default.
      _caps = {
        for (final k in [
          'vision',
          'file_upload',
          'web_search',
          'image_generation',
          'code_interpreter',
          'citations',
          'status_updates',
          'builtin_tools',
        ])
          k: true,
      };
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final id = _isNew ? modelIdFrom(_id.text.trim()) : _m!.id;
    if (name.isEmpty || id.isEmpty || _base == null) {
      _say(context, 'Name, id and base model are needed');
      return;
    }
    final kbs = ref.read(knowledgeListProvider).value ?? const [];
    final old = _m?.json ?? <String, dynamic>{};
    final meta = {...?_m?.meta};
    final params = {...?_m?.params};
    meta['description'] = _description.text.trim();
    meta['capabilities'] = _caps;
    meta['toolIds'] = _tools.toList();
    meta['skillIds'] = _skills.toList();
    meta['knowledge'] = [
      for (final id in _knowledge)
        () {
          final k = kbs.where((k) => k.id == id).firstOrNull;
          // Keep how the server stored ones the app can't list.
          final kept = (_m?.meta['knowledge'] as List? ?? const [])
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
    meta['profile_image_url'] ??= '/static/favicon.png';
    final system = _system.text.trim();
    if (system.isEmpty) {
      params.remove('system');
    } else {
      params['system'] = system;
    }
    setState(() => _busy = true);
    try {
      await ref.read(modelsApiProvider).save({
        ...old,
        'id': id,
        'name': name,
        'base_model_id': _base,
        'meta': meta,
        'params': params,
        'is_active': _m?.active ?? true,
      }, create: _isNew);
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
        title: Text('Delete ${_m!.name}?'),
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
          if (!_isNew && writable)
            IconButton(
              tooltip: 'Delete',
              onPressed: _busy || _loading ? null : _delete,
              icon: const Icon(Icons.delete_outline),
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
              ],
            ),
    );
  }
}
