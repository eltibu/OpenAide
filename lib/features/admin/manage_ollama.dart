/// Admin > Models > Manage: the server's Ollama models, as the web's
/// Manage Ollama: pull (with progress, cancel), update all, delete, create,
/// a GGUF file from the phone or a link, and unload from memory.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart' show modelsProvider;
import '../chat/file_details.dart' show fileSize;
import 'ollama_pulls.dart';

export 'ollama_pulls.dart' show pullPercent;

class ManageOllamaScreen extends ConsumerStatefulWidget {
  const ManageOllamaScreen({super.key});

  @override
  ConsumerState<ManageOllamaScreen> createState() => _ManageOllamaState();
}

class _ManageOllamaState extends ConsumerState<ManageOllamaScreen> {
  List<String> _urls = [];
  int _idx = 0;
  String? _version;
  List<Map<String, dynamic>> _models = [];
  Object? _error;
  bool _loading = true;
  final _tag = TextEditingController();
  final _link = TextEditingController();

  String? _uploading;

  String get _at => '/$_idx';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tag.dispose();
    _link.dispose();
    super.dispose();
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _load() async {
    final client = ref.read(clientProvider);
    setState(() => _loading = true);
    try {
      final config = await client.send('GET', '/ollama/config') as Map;
      if (config['ENABLE_OLLAMA_API'] == false) {
        throw 'Ollama is off. Turn it on in Admin > Connections.';
      }
      _urls = [for (final u in config['OLLAMA_BASE_URLS'] as List? ?? []) '$u'];
      if (_idx >= _urls.length) _idx = 0;
      final v = await client.send('GET', '/ollama/api/version$_at');
      _version = (v as Map?)?['version']?.toString();
      final tags = await client.send('GET', '/ollama/api/tags$_at');
      _models = [
        for (final m in ((tags as Map?)?['models'] as List? ?? []))
          if (m is Map) m.cast<String, dynamic>(),
      ];
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _refreshEverywhere() {
    ref.invalidate(modelsProvider);
    _load();
  }

  /// Pulls keep going after this screen closes; see [ollamaPullsProvider].
  Future<void> _pull(String tag) async {
    tag = tag.trim();
    if (tag.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final (end, error) = await ref
        .read(ollamaPullsProvider.notifier)
        .pull(tag, server: _idx);
    messenger.showSnackBar(
      SnackBar(
        content: Text(switch (end) {
          PullEnd.ready => 'Model $tag is ready',
          PullEnd.cancelled => 'Download of $tag cancelled',
          PullEnd.failed => '$tag: $error',
        }),
      ),
    );
    if (mounted) _load();
  }

  void _cancel(String tag) =>
      ref.read(ollamaPullsProvider.notifier).cancel(tag);

  Future<void> _updateAll() async {
    for (final m in [..._models]) {
      await _pull('${m['name']}');
    }
  }

  Future<void> _delete(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text('It is removed from the Ollama server.'),
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
          .send('DELETE', '/ollama/api/delete$_at', body: {'model': name});
      _say('Deleted $name');
    } catch (e) {
      _say('$e');
    }
    _refreshEverywhere();
  }

  Future<void> _unload(String name) async {
    try {
      await ref
          .read(clientProvider)
          .send('POST', '/ollama/api/unload', body: {'model': name});
      _say('$name unloaded from memory');
    } catch (e) {
      _say('$e');
    }
  }

  Future<void> _create() async {
    final name = TextEditingController();
    final from = TextEditingController();
    final system = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Create Model'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(
                labelText: 'Model tag name',
                hintText: 'my-modelfile',
              ),
            ),
            TextField(
              controller: from,
              decoration: const InputDecoration(
                labelText: 'From',
                hintText: 'llama3.2',
              ),
            ),
            TextField(
              controller: system,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(labelText: 'System prompt'),
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
    if (ok != true || name.text.trim().isEmpty) return;
    try {
      await ref
          .read(clientProvider)
          .streamJson('POST', '/ollama/api/create$_at', {
            'model': name.text.trim(),
            if (from.text.trim().isNotEmpty) 'from': from.text.trim(),
            if (system.text.trim().isNotEmpty) 'system': system.text.trim(),
            'stream': true,
          })
          .forEach((p) {
            if (p['error'] != null) throw '${p['error']}';
          });
      _say('Model ${name.text.trim()} created');
    } catch (e) {
      _say('$e');
    }
    _refreshEverywhere();
  }

  /// A GGUF file from the phone, or from a link the server downloads.
  Future<void> _upload({bool link = false}) async {
    final client = ref.read(clientProvider);
    try {
      if (link) {
        final url = _link.text.trim();
        if (url.isEmpty) return;
        setState(() => _uploading = url.split('/').last);
        await client
            .streamJson('POST', '/ollama/models/download$_at', {'url': url})
            .forEach((p) {
              if (p['error'] != null) throw '${p['error']}';
            });
      } else {
        final picked = await FilePicker.pickFiles();
        final f = picked.firstOrNull;
        if (f == null) return;
        setState(() => _uploading = f.name);
        await client.sendFile(
          '/ollama/models/upload$_at',
          await f.readAsBytes(),
          f.name,
        );
      }
      _say('Uploaded $_uploading');
    } catch (e) {
      _say('$e');
    }
    if (mounted) setState(() => _uploading = null);
    _refreshEverywhere();
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(color: NexusColors.accent),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Ollama'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading && _models.isEmpty && _error == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('$_error', textAlign: TextAlign.center),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                if (_urls.length > 1)
                  ListTile(
                    title: const Text('Ollama server'),
                    subtitle: DropdownButton<int>(
                      value: _idx,
                      isExpanded: true,
                      items: [
                        for (final (i, u) in _urls.indexed)
                          DropdownMenuItem(value: i, child: Text(u)),
                      ],
                      onChanged: (i) {
                        setState(() => _idx = i ?? 0);
                        _load();
                      },
                    ),
                  ),
                if (_version != null)
                  ListTile(
                    title: Text(_urls.elementAtOrNull(_idx) ?? 'Ollama'),
                    subtitle: Text('Ollama $_version'),
                  ),
                heading('Pull a model from Ollama.com'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _tag,
                    decoration: InputDecoration(
                      hintText: 'Enter model tag (e.g. mistral:7b)',
                      suffixIcon: IconButton(
                        tooltip: 'Pull Model',
                        icon: const Icon(Icons.download),
                        onPressed: () {
                          _pull(_tag.text);
                          _tag.clear();
                        },
                      ),
                    ),
                    onSubmitted: (v) {
                      _pull(v);
                      _tag.clear();
                    },
                  ),
                ),
                for (final p in ref.watch(ollamaPullsProvider).entries)
                  ListTile(
                    title: Text(p.key),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: p.value.$2 == null ? null : p.value.$2! / 100,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          p.value.$2 == null
                              ? p.value.$1
                              : '${p.value.$1} · ${p.value.$2!.toStringAsFixed(1)}%',
                          style: TextStyle(color: muted),
                        ),
                      ],
                    ),
                    trailing: IconButton(
                      tooltip: 'Cancel download of ${p.key}',
                      icon: const Icon(Icons.close),
                      onPressed: () => _cancel(p.key),
                    ),
                  ),
                heading('Models (${_models.length})'),
                for (final m in _models)
                  ListTile(
                    title: Text('${m['name']}'),
                    subtitle: Text(
                      [
                        fileSize(m['size'] as num?),
                        if ((m['details'] as Map?)?['parameter_size'] != null)
                          '${(m['details'] as Map)['parameter_size']}',
                        if ((m['details'] as Map?)?['quantization_level'] !=
                            null)
                          '${(m['details'] as Map)['quantization_level']}',
                      ].where((t) => t.isNotEmpty).join(' · '),
                      style: TextStyle(color: muted),
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) => switch (v) {
                        'update' => _pull('${m['name']}'),
                        'unload' => _unload('${m['name']}'),
                        _ => _delete('${m['name']}'),
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'update', child: Text('Update')),
                        PopupMenuItem(
                          value: 'unload',
                          child: Text('Unload Model'),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete Model'),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.update),
                        label: const Text('Update All Models'),
                        onPressed: _models.isEmpty ? null : _updateAll,
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Create Model'),
                        onPressed: _create,
                      ),
                    ],
                  ),
                ),
                heading('Upload a GGUF model'),
                if (_uploading != null)
                  ListTile(
                    title: Text('Uploading $_uploading'),
                    subtitle: const LinearProgressIndicator(),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Upload Model'),
                        onPressed: _uploading == null ? _upload : null,
                      ),
                      TextField(
                        controller: _link,
                        decoration: InputDecoration(
                          hintText: 'Or a link to a .gguf file',
                          suffixIcon: IconButton(
                            tooltip: 'Download Model',
                            icon: const Icon(Icons.cloud_download_outlined),
                            onPressed: _uploading == null
                                ? () => _upload(link: true)
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
