/// Admin > Evaluations: arena models, which answer as a model picked at
/// random (from all models, or only some, or all but some) so people can
/// rate replies blind.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart' show modelsProvider;
import '../workspace/models_api.dart' show modelIdFrom;

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

const _path = '/api/v1/evaluations/config';

/// [model] as the server keeps it: no model list means all models, so no
/// filter either.
Map<String, dynamic> arenaModel({
  required String id,
  required String name,
  required Map<String, dynamic> meta,
  required String description,
  required String? image,
  required List<String> modelIds,
  required String filterMode,
}) => {
  'id': id,
  'name': name,
  'meta': {
    ...meta,
    'profile_image_url': image ?? '/favicon.png',
    'description': description.trim().isEmpty ? null : description.trim(),
    'model_ids': modelIds.isEmpty ? null : modelIds,
    'filter_mode': modelIds.isEmpty ? null : filterMode,
    'access_grants': meta['access_grants'] ?? [],
  },
};

/// What an arena model picks from, in words.
String arenaPicksFrom(Map meta, Map<String, String> names) {
  final ids = [for (final i in meta['model_ids'] as List? ?? const []) '$i'];
  if (ids.isEmpty) return 'All models';
  final list = ids.map((i) => names[i] ?? i).join(', ');
  return meta['filter_mode'] == 'exclude' ? 'All but $list' : list;
}

class ArenaScreen extends ConsumerStatefulWidget {
  const ArenaScreen({super.key});

  @override
  ConsumerState<ArenaScreen> createState() => _ArenaScreenState();
}

class _ArenaScreenState extends ConsumerState<ArenaScreen> {
  Map<String, dynamic>? _config;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _config = ((await ref.read(clientProvider).send('GET', _path)) as Map)
          .cast<String, dynamic>();
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  List<Map<String, dynamic>> get _models => [
    for (final m in _config?['EVALUATION_ARENA_MODELS'] as List? ?? const [])
      if (m is Map) m.cast<String, dynamic>(),
  ];

  Future<void> _save(Map<String, dynamic> next) async {
    setState(() => _busy = true);
    try {
      _config =
          ((await ref.read(clientProvider).send('POST', _path, body: next))
                  as Map)
              .cast<String, dynamic>();
      // Arena models show up in the model list.
      ref.invalidate(modelsProvider);
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _edit([int? index]) async {
    final model = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => _ArenaEditor(
          model: index == null ? null : _models[index],
          taken: {
            for (final (i, m) in _models.indexed)
              if (i != index) '${m['id']}',
          },
        ),
      ),
    );
    if (model == null) return;
    final list = _models;
    if (index == null) {
      list.add(model);
    } else {
      list[index] = model;
    }
    await _save({..._config!, 'EVALUATION_ARENA_MODELS': list});
  }

  Future<void> _delete(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${_models[index]['name']}?'),
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
    await _save({
      ..._config!,
      'EVALUATION_ARENA_MODELS': _models..removeAt(index),
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    final muted = context.nexus.muted;
    final names = <String, String>{
      for (final m in ref.watch(modelsProvider).value ?? const []) m.id: m.name,
    };
    final on = config?['ENABLE_EVALUATION_ARENA_MODELS'] == true;
    return Scaffold(
      appBar: AppBar(title: const Text('Evaluations')),
      floatingActionButton: on
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _edit,
              icon: const Icon(Icons.add),
              label: const Text('Add Arena Model'),
            )
          : null,
      body: config == null
          ? Center(
              child: _error != null
                  ? Text("Couldn't load the settings.\n$_error")
                  : const CircularProgressIndicator(),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                SwitchListTile(
                  title: const Text('Arena Models'),
                  subtitle: Text(
                    'Models that answer as one picked at random, so replies '
                    'are rated blind.',
                    style: TextStyle(color: muted),
                  ),
                  value: on,
                  onChanged: _busy
                      ? null
                      : (v) => _save({
                          ...config,
                          'ENABLE_EVALUATION_ARENA_MODELS': v,
                        }),
                ),
                if (on && _models.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No arena models yet. The server adds a default one.',
                      style: TextStyle(color: muted),
                    ),
                  ),
                if (on)
                  for (final (i, m) in _models.indexed)
                    ListTile(
                      leading: const Icon(Icons.casino_outlined),
                      title: Text('${m['name']}'),
                      subtitle: Text(
                        arenaPicksFrom(m['meta'] as Map? ?? const {}, names),
                        style: TextStyle(color: muted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _edit(i),
                      trailing: IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _busy ? null : () => _delete(i),
                      ),
                    ),
              ],
            ),
    );
  }
}

class _ArenaEditor extends ConsumerStatefulWidget {
  const _ArenaEditor({this.model, required this.taken});
  final Map<String, dynamic>? model;
  final Set<String> taken;

  @override
  ConsumerState<_ArenaEditor> createState() => _ArenaEditorState();
}

class _ArenaEditorState extends ConsumerState<_ArenaEditor> {
  late final Map<String, dynamic> _meta = {
    ...?(widget.model?['meta'] as Map?)?.cast<String, dynamic>(),
  };
  late final _name = TextEditingController(
    text: '${widget.model?['name'] ?? ''}',
  );
  late final _id = TextEditingController(text: '${widget.model?['id'] ?? ''}');
  late final _description = TextEditingController(
    text: '${_meta['description'] ?? ''}',
  );
  late final Set<String> _ids = {
    for (final i in _meta['model_ids'] as List? ?? const []) '$i',
  };
  late String _filter = _meta['filter_mode'] == 'exclude'
      ? 'exclude'
      : 'include';
  late String? _image = _meta['profile_image_url'] as String?;
  bool _idEdited = false;

  bool get _isNew => widget.model == null;

  Future<void> _pickImage() async {
    final photo = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 250,
      maxHeight: 250,
      imageQuality: 85,
    );
    if (photo == null) return;
    final bytes = await photo.readAsBytes();
    final type = (photo.mimeType ?? '').contains('png')
        ? 'image/png'
        : 'image/jpeg';
    setState(() => _image = 'data:$type;base64,${base64Encode(bytes)}');
  }

  void _done() {
    final name = _name.text.trim();
    final id = _isNew ? modelIdFrom(_id.text.trim()) : '${widget.model!['id']}';
    if (name.isEmpty || id.isEmpty) return _say(context, 'Give it a name');
    if (widget.taken.contains(id)) {
      return _say(
        context,
        'Model name already exists, please choose a different one',
      );
    }
    Navigator.pop(
      context,
      arenaModel(
        id: id,
        name: name,
        meta: _meta,
        description: _description.text,
        image: _image,
        modelIds: _ids.toList(),
        filterMode: _filter,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final models = [
      for (final m in ref.watch(modelsProvider).value ?? const [])
        // Arena models can't pick each other.
        if (m.raw['owned_by'] != 'arena') m,
    ];
    final muted = context.nexus.muted;
    final image = _image ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Add Arena Model' : 'Edit Arena Model'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _done, child: const Text('Done')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundImage: image.startsWith('data:image/')
                    ? MemoryImage(
                        base64Decode(image.substring(image.indexOf(',') + 1)),
                      )
                    : null,
                child: image.startsWith('data:image/')
                    ? null
                    : const Icon(Icons.casino_outlined),
              ),
              const SizedBox(width: 12),
              TextButton.icon(
                icon: const Icon(Icons.photo_outlined),
                label: const Text('Profile'),
                onPressed: _pickImage,
              ),
            ],
          ),
          TextField(
            controller: _name,
            autofocus: _isNew,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (v) {
              if (_isNew && !_idEdited) _id.text = modelIdFrom(v);
            },
          ),
          TextField(
            controller: _id,
            enabled: _isNew,
            decoration: const InputDecoration(labelText: 'ID'),
            onChanged: (_) => _idEdited = true,
          ),
          TextField(
            controller: _description,
            maxLines: null,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
          const SizedBox(height: 16),
          Text('Models', style: Theme.of(context).textTheme.titleSmall),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'include', label: Text('Include')),
                ButtonSegment(value: 'exclude', label: Text('Exclude')),
              ],
              selected: {_filter},
              onSelectionChanged: (v) => setState(() => _filter = v.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _ids.isEmpty
                  ? 'Leave empty to include all models or select specific models'
                  : _filter == 'include'
                  ? 'Picks one of the ${_ids.length} chosen.'
                  : 'Picks any model but the ${_ids.length} chosen.',
              style: TextStyle(color: muted),
            ),
          ),
          for (final m in models)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(m.name),
              value: _ids.contains(m.id),
              onChanged: (on) => setState(
                () => on == true ? _ids.add(m.id) : _ids.remove(m.id),
              ),
            ),
        ],
      ),
    );
  }
}
