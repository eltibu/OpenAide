/// Admin > Pipelines: the pipelines on each Pipelines server connected as a
/// model connection; install from a URL or a .py file, set valves, delete.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../workspace/tools_skills.dart' show ValvesScreen;

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

const _base = '/api/v1/pipelines';

class PipelinesScreen extends ConsumerStatefulWidget {
  const PipelinesScreen({super.key});

  @override
  ConsumerState<PipelinesScreen> createState() => _PipelinesScreenState();
}

class _PipelinesScreenState extends ConsumerState<PipelinesScreen> {
  /// Pipelines servers: (url, index among the model connections).
  List<({String url, int idx})>? _servers;
  int? _idx;
  List<Map<String, dynamic>>? _pipelines;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  Future<void> _loadServers() async {
    try {
      final res =
          await ref.read(clientProvider).send('GET', '$_base/list') as Map;
      _servers = [
        for (final s in res['data'] as List? ?? const [])
          if (s is Map) (url: '${s['url']}', idx: (s['idx'] as num).toInt()),
      ];
      _idx ??= _servers!.firstOrNull?.idx;
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
    await _loadPipelines();
  }

  Future<void> _loadPipelines() async {
    final idx = _idx;
    if (idx == null) return;
    setState(() => _pipelines = null);
    try {
      final res =
          await ref
                  .read(clientProvider)
                  .send('GET', '$_base/', query: {'urlIdx': '$idx'})
              as Map;
      _pipelines = [
        for (final p in res['data'] as List? ?? const [])
          if (p is Map) p.cast<String, dynamic>(),
      ];
    } catch (e) {
      _pipelines = const [];
      if (mounted) _say(context, 'Couldn\'t list pipelines: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() job, String done) async {
    setState(() => _busy = true);
    try {
      await job();
      if (mounted) _say(context, done);
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    if (mounted) setState(() => _busy = false);
    await _loadPipelines();
  }

  Future<void> _addFromUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Install from GitHub URL'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://github.com/…/pipeline.py',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, controller.text.trim()),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    await _run(
      () => ref
          .read(clientProvider)
          .send('POST', '$_base/add', body: {'url': url, 'urlIdx': _idx}),
      'Installed',
    );
  }

  Future<void> _upload() async {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    final f = picked.first;
    if (!f.name.endsWith('.py')) {
      if (mounted) _say(context, 'Pick a Python (.py) file');
      return;
    }
    final bytes = await f.readAsBytes();
    await _run(
      () => ref
          .read(clientProvider)
          .sendFile(
            '$_base/upload',
            bytes,
            f.name,
            fields: {'urlIdx': '$_idx'},
          ),
      'Uploaded ${f.name}',
    );
  }

  Future<void> _delete(Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${p['name'] ?? p['id']}?'),
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
    await _run(
      () => ref
          .read(clientProvider)
          .send(
            'DELETE',
            '$_base/delete',
            body: {'id': p['id'], 'urlIdx': _idx},
          ),
      'Deleted',
    );
  }

  @override
  Widget build(BuildContext context) {
    final servers = _servers;
    final muted = context.nexus.muted;
    final pipelines = _pipelines;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pipelines'),
        actions: [
          if (_idx != null)
            PopupMenuButton<String>(
              enabled: !_busy,
              icon: const Icon(Icons.add),
              tooltip: 'Install',
              onSelected: (v) => v == 'url' ? _addFromUrl() : _upload(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'url', child: Text('From a GitHub URL')),
                PopupMenuItem(value: 'file', child: Text('Upload a .py file')),
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
      body: servers == null
          ? Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Couldn\'t load pipelines.\n$_error'),
                    )
                  : const CircularProgressIndicator(),
            )
          : servers.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No Pipelines server is connected. Add one under Model '
                'connections (OpenAI-compatible) and it shows here.',
                style: TextStyle(color: muted),
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadServers,
              child: ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: DropdownButtonFormField<int>(
                      initialValue: _idx,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Pipelines server',
                      ),
                      items: [
                        for (final s in servers)
                          DropdownMenuItem(
                            value: s.idx,
                            child: Text(s.url, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (v) {
                        _idx = v;
                        _loadPipelines();
                      },
                    ),
                  ),
                  if (pipelines == null)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (pipelines.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No pipelines on this server yet.',
                        style: TextStyle(color: muted),
                      ),
                    ),
                  for (final p in pipelines ?? const <Map<String, dynamic>>[])
                    ListTile(
                      leading: const Icon(Icons.account_tree_outlined),
                      title: Text('${p['name'] ?? p['id']}'),
                      subtitle: Text(
                        [
                          '${p['id']}',
                          if (p['type'] != null) '${p['type']}',
                        ].join(' · '),
                        style: TextStyle(color: muted),
                      ),
                      onTap: _busy
                          ? null
                          : () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => ValvesScreen(
                                  title: '${p['name'] ?? p['id']}',
                                  specPath:
                                      '$_base/${p['id']}/valves/spec?urlIdx=$_idx',
                                  valuesPath:
                                      '$_base/${p['id']}/valves?urlIdx=$_idx',
                                  savePath:
                                      '$_base/${p['id']}/valves/update?urlIdx=$_idx',
                                ),
                              ),
                            ),
                      trailing: IconButton(
                        tooltip: 'Delete',
                        onPressed: _busy ? null : () => _delete(p),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
