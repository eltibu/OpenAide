/// Admin > Models > Model providers: models on a llama.cpp or LM Studio
/// connection, as the web's Manage Models for those: download by name,
/// load, unload and (llama.cpp) delete.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart' show modelsProvider;

/// Connection kinds the server can manage models on.
const managedProviders = {'llama.cpp', 'lmstudio'};

typedef ProviderConnection = ({int idx, String url, String provider});

/// The OpenAI-style connections that are llama.cpp or LM Studio, from the
/// server's /openai/config, as the web finds them.
List<ProviderConnection> providerConnections(Map? config) {
  if (config == null || config['ENABLE_OPENAI_API'] == false) return const [];
  final urls = [
    for (final u in config['OPENAI_API_BASE_URLS'] as List? ?? []) '$u',
  ];
  final configs = config['OPENAI_API_CONFIGS'] as Map? ?? const {};
  return [
    for (var i = 0; i < urls.length; i++)
      if ((configs['$i'] ?? configs[urls[i]]) case final Map c
          when managedProviders.contains(c['provider']))
        (idx: i, url: urls[i], provider: '${c['provider']}'),
  ];
}

String providerLabel(String provider) => switch (provider) {
  'lmstudio' => 'LM Studio',
  _ => provider,
};

/// The models in a provider's catalog, by name.
List<Map<String, dynamic>> providerModelsFrom(Object? res) {
  final entries = res is List
      ? res
      : res is Map
      ? (res['models'] ?? res['data'] ?? res['items'] ?? const []) as List
      : const [];
  final out = [
    for (final m in entries)
      if (m is String)
        {'id': m, 'name': m}
      else if (m is Map)
        m.cast<String, dynamic>(),
  ].where((m) => providerModelId(m).isNotEmpty).toList();
  out.sort((a, b) => providerModelId(a).compareTo(providerModelId(b)));
  return out;
}

String providerModelId(Map m) =>
    '${m['key'] ?? m['id'] ?? m['name'] ?? m['model'] ?? ''}';

/// loaded, loading, sleeping, unloaded, available…
String providerModelStatus(Map m, String provider) {
  if ((m['loaded_instances'] as List?)?.isNotEmpty == true) return 'loaded';
  if (provider == 'lmstudio') return 'unloaded';
  final s = m['status'];
  if (s is String) return s;
  if (s is Map && s['value'] != null) return '${s['value']}';
  return 'available';
}

class ProviderModelsScreen extends ConsumerStatefulWidget {
  const ProviderModelsScreen({super.key, required this.connections});
  final List<ProviderConnection> connections;

  @override
  ConsumerState<ProviderModelsScreen> createState() => _ProviderModelsState();
}

class _ProviderModelsState extends ConsumerState<ProviderModelsScreen> {
  late ProviderConnection _at = widget.connections.first;
  List<Map<String, dynamic>> _models = [];
  bool _loading = true;
  String? _busy;
  Object? _error;
  final _ref = TextEditingController();

  String get _base => '/openai/models/${_at.idx}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ref.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _models = providerModelsFrom(
        await ref.read(clientProvider).send('GET', '$_base/catalog'),
      );
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _run(
    String model,
    Future<void> Function() action,
    String done,
  ) async {
    setState(() => _busy = model);
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr(done))));
      }
      ref.invalidate(modelsProvider);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) setState(() => _busy = null);
  }

  Future<void> _download() async {
    final model = _ref.text.trim();
    if (model.isEmpty) return;
    await _run(
      model,
      () => ref
          .read(clientProvider)
          .send('POST', '$_base/download', body: {'model': model}),
      'Model download started',
    );
    _ref.clear();
  }

  Future<void> _loadModel(String model) => _run(
    model,
    () => ref
        .read(clientProvider)
        .send('POST', '$_base/load', body: {'model': model}),
    'Model loaded successfully',
  );

  Future<void> _unload(Map m) {
    final model = providerModelId(m);
    final instance = (m['loaded_instances'] as List?)?.firstOrNull;
    return _run(
      model,
      () => ref
          .read(clientProvider)
          .send(
            'POST',
            '$_base/unload',
            body: {
              'model': model,
              if (instance is Map && instance['id'] != null)
                'instance_id': '${instance['id']}',
            },
          ),
      'Model unloaded successfully',
    );
  }

  Future<void> _delete(String model) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const T('Delete Model'),
        content: const T(
          'This will delete the cached model and cannot be undone.',
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
    await _run(
      model,
      () => ref
          .read(clientProvider)
          .send('DELETE', _base, query: {'model': model}),
      'Model deleted successfully',
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final idle = _busy == null;
    return Scaffold(
      appBar: AppBar(
        title: const T('Model providers'),
        actions: [
          IconButton(
            tooltip: tr('Refresh'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: _loading || !idle
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (widget.connections.length > 1)
            DropdownButtonFormField<int>(
              initialValue: _at.idx,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('Connection')),
              items: [
                for (final c in widget.connections)
                  DropdownMenuItem(
                    value: c.idx,
                    child: Text(
                      '${providerLabel(c.provider)} - ${c.url}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (i) {
                _at = widget.connections.firstWhere((c) => c.idx == i);
                _load();
              },
            )
          else
            Text(
              '${providerLabel(_at.provider)} - ${_at.url}',
              style: TextStyle(color: muted),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ref,
                  decoration: InputDecoration(
                    labelText: tr('Type a model ref'),
                  ),
                  onSubmitted: (_) => _download(),
                ),
              ),
              IconButton(
                tooltip: tr('Download Model'),
                icon: const Icon(Icons.download_outlined),
                onPressed: idle ? _download : null,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Text('$_error', style: TextStyle(color: muted))
          else if (!_loading && _models.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: T(
                'No models found',
                textAlign: TextAlign.center,
                style: TextStyle(color: muted),
              ),
            ),
          for (final m in _models)
            Builder(
              builder: (context) {
                final id = providerModelId(m);
                final name = '${m['display_name'] ?? id}';
                final status = providerModelStatus(m, _at.provider);
                return Card(
                  child: ListTile(
                    title: Text(name, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      name == id ? tr(status) : '$id · ${tr(status)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: tr('Load Model'),
                          icon: const Icon(Icons.play_arrow_outlined),
                          onPressed:
                              idle && status != 'loaded' && status != 'loading'
                              ? () => _loadModel(id)
                              : null,
                        ),
                        IconButton(
                          tooltip: tr('Unload Model'),
                          icon: const Icon(Icons.eject_outlined),
                          onPressed: idle && status != 'unloaded'
                              ? () => _unload(m)
                              : null,
                        ),
                        if (_at.provider == 'llama.cpp')
                          IconButton(
                            tooltip: tr('Delete Model'),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: idle ? () => _delete(id) : null,
                          ),
                      ],
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
