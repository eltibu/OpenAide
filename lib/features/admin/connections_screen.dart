/// Admin > Connections, as on the web: the OpenAI-compatible and Ollama
/// servers the models come from, each with its address, key, prefix and
/// models, plus a check that it answers.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart' show modelsProvider;

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// One kind of model server and how its settings are named.
class ConnectionKind {
  const ConnectionKind({
    required this.title,
    required this.base,
    required this.enableKey,
    required this.urlsKey,
    required this.configsKey,
    this.keysKey,
  });

  final String title;

  /// '/openai' or '/ollama'.
  final String base;
  final String enableKey;
  final String urlsKey;
  final String configsKey;

  /// Where keys live, beside the addresses; null when each connection keeps
  /// its key in its own settings (Ollama).
  final String? keysKey;
}

const openAiConnections = ConnectionKind(
  title: 'OpenAI API',
  base: '/openai',
  enableKey: 'ENABLE_OPENAI_API',
  urlsKey: 'OPENAI_API_BASE_URLS',
  keysKey: 'OPENAI_API_KEYS',
  configsKey: 'OPENAI_API_CONFIGS',
);

const ollamaConnections = ConnectionKind(
  title: 'Ollama API',
  base: '/ollama',
  enableKey: 'ENABLE_OLLAMA_API',
  urlsKey: 'OLLAMA_BASE_URLS',
  configsKey: 'OLLAMA_API_CONFIGS',
);

/// One connection pulled out of a kind's settings.
class Connection {
  Connection({required this.url, this.key = '', Map? config})
    : config = config == null
          ? <String, dynamic>{}
          : (jsonDecode(jsonEncode(config)) as Map).cast<String, dynamic>();

  String url;
  String key;
  Map<String, dynamic> config;

  bool get enabled => config['enable'] != false;
}

List<Connection> readConnections(ConnectionKind k, Map settings) {
  final urls = [for (final u in settings[k.urlsKey] as List? ?? const []) '$u'];
  final keys = [for (final u in settings[k.keysKey] as List? ?? const []) '$u'];
  final configs = (settings[k.configsKey] as Map?) ?? const {};
  return [
    for (final (i, url) in urls.indexed)
      Connection(
        url: url,
        key: k.keysKey == null
            ? '${(configs['$i'] as Map?)?['key'] ?? ''}'
            : (i < keys.length ? keys[i] : ''),
        config: configs['$i'] as Map?,
      ),
  ];
}

/// The settings to save for [list], indexes renumbered as on the web.
Map<String, dynamic> writeConnections(
  ConnectionKind k,
  bool enabled,
  List<Connection> list,
) => {
  k.enableKey: enabled,
  k.urlsKey: [for (final c in list) c.url],
  if (k.keysKey != null) k.keysKey!: [for (final c in list) c.key],
  k.configsKey: {
    for (final (i, c) in list.indexed)
      '$i': {
        ...c.config,
        if (k.keysKey == null && c.key.isNotEmpty) 'key': c.key,
      },
  },
};

class ConnectionsScreen extends ConsumerStatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  ConsumerState<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends ConsumerState<ConnectionsScreen> {
  final _on = <ConnectionKind, bool>{};
  final _lists = <ConnectionKind, List<Connection>>{};
  Object? _error;
  bool _loaded = false;

  static const _kinds = [openAiConnections, ollamaConnections];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(clientProvider);
    try {
      for (final k in _kinds) {
        final s = await client.send('GET', '${k.base}/config') as Map;
        _on[k] = s[k.enableKey] == true;
        _lists[k] = readConnections(k, s);
      }
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _save(ConnectionKind k) async {
    try {
      await ref
          .read(clientProvider)
          .send(
            'POST',
            '${k.base}/config/update',
            body: writeConnections(k, _on[k]!, _lists[k]!),
          );
      // The model list follows the connections.
      ref.invalidate(modelsProvider);
    } catch (e) {
      if (mounted) _say(context, 'Not saved: $e');
      await _load();
    }
    if (mounted) setState(() {});
  }

  Future<void> _edit(ConnectionKind k, Connection? c) async {
    final result = await Navigator.push<Object>(
      context,
      MaterialPageRoute(
        builder: (_) => ConnectionEditor(kind: k, connection: c),
      ),
    );
    if (result == null) return;
    final list = _lists[k]!;
    if (result == 'delete') {
      list.remove(c);
    } else if (result is Connection && c == null) {
      list.add(result);
    }
    await _save(k);
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final heading = Theme.of(context).textTheme.titleSmall;
    return Scaffold(
      appBar: AppBar(title: const Text('Model connections')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('Couldn\'t load connections.\n$_error'))
          : ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                for (final k in _kinds) ...[
                  SwitchListTile(
                    title: Text(k.title, style: heading),
                    value: _on[k]!,
                    onChanged: (on) {
                      setState(() => _on[k] = on);
                      _save(k);
                    },
                  ),
                  for (final c in _lists[k]!)
                    ListTile(
                      leading: Icon(
                        Icons.cable,
                        color: c.enabled ? null : muted,
                      ),
                      title: Text(
                        c.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          if ('${c.config['prefix_id'] ?? ''}'.isNotEmpty)
                            'Prefix ${c.config['prefix_id']}',
                          if ((c.config['model_ids'] as List?)?.isNotEmpty ==
                              true)
                            '${(c.config['model_ids'] as List).length} models',
                          if (!c.enabled) 'Off',
                        ].join(' · ').ifEmpty('All models'),
                      ),
                      trailing: Switch(
                        value: c.enabled,
                        onChanged: (on) {
                          setState(() => c.config['enable'] = on);
                          _save(k);
                        },
                      ),
                      onTap: () => _edit(k, c),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: TextButton.icon(
                        onPressed: () => _edit(k, null),
                        icon: const Icon(Icons.add),
                        label: const Text('Add connection'),
                      ),
                    ),
                  ),
                  const Divider(),
                ],
              ],
            ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// Adds a connection or changes one; pops the connection, or 'delete'.
class ConnectionEditor extends ConsumerStatefulWidget {
  const ConnectionEditor({super.key, required this.kind, this.connection});
  final ConnectionKind kind;
  final Connection? connection;

  @override
  ConsumerState<ConnectionEditor> createState() => _ConnectionEditorState();
}

class _ConnectionEditorState extends ConsumerState<ConnectionEditor> {
  late final Connection _c =
      widget.connection ??
      Connection(
        url: widget.kind == ollamaConnections
            ? 'http://localhost:11434'
            : 'https://api.openai.com/v1',
      );
  late final _url = TextEditingController(text: _c.url);
  late final _key = TextEditingController(text: _c.key);
  late final _prefix = TextEditingController(
    text: '${_c.config['prefix_id'] ?? ''}',
  );
  late final _models = TextEditingController(
    text: [for (final m in _c.config['model_ids'] as List? ?? const []) m]
        .join(', '),
  );
  late final _tags = TextEditingController(
    text: [
      for (final t in _c.config['tags'] as List? ?? const [])
        t is Map ? '${t['name']}' : '$t',
    ].join(', '),
  );
  late String _authType = '${_c.config['auth_type'] ?? 'bearer'}';
  late bool _local = _c.config['connection_type'] == 'local';
  late bool _responses = _c.config['api_type'] == 'responses';
  late bool _cookies = _c.config['forward_cookies'] == true;
  late String _provider =
      '${_c.config['provider'] ?? (_c.config['azure'] == true ? 'azure' : '')}';
  late final _apiVersion = TextEditingController(
    text: '${_c.config['api_version'] ?? ''}',
  );
  late final _headers = TextEditingController(
    text: _c.config['headers'] is Map
        ? const JsonEncoder.withIndent('  ').convert(_c.config['headers'])
        : '',
  );
  late final _passthrough = TextEditingController(
    text: _c.config['passthrough_params'] is List
        ? (_c.config['passthrough_params'] as List).join(', ')
        : '${_c.config['passthrough_params'] ?? ''}',
  );
  bool _hidden = true;

  /// Azure by choice, or by an Azure address with no provider picked.
  bool get _azure {
    final url = _url.text;
    return _provider == 'azure' ||
        (_provider.isEmpty &&
            (url.contains('azure.') ||
                url.contains('cognitive.microsoft.com')) &&
            !RegExp(r'/openai/v1(/|$)').hasMatch(url));
  }

  bool _checking = false;

  @override
  void dispose() {
    for (final c in [
      _url,
      _key,
      _prefix,
      _models,
      _tags,
      _apiVersion,
      _headers,
      _passthrough,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _split(String s) => [
    for (final x in s.split(','))
      if (x.trim().isNotEmpty) x.trim(),
  ];

  /// False, with a note, when the headers aren't a JSON object.
  bool _apply() {
    Object? headers;
    if (_headers.text.trim().isNotEmpty) {
      try {
        headers = jsonDecode(_headers.text);
      } catch (_) {}
      if (headers is! Map) {
        _say(context, 'Headers must be a JSON object');
        return false;
      }
    }
    final openAi = widget.kind == openAiConnections;
    _c
      ..url = _url.text.trim().replaceAll(RegExp(r'/+$'), '')
      ..key = _key.text.trim();
    _c.config
      ..['enable'] = _c.config['enable'] ?? true
      ..['prefix_id'] = _prefix.text.trim()
      ..['model_ids'] = _split(_models.text)
      ..['tags'] = [
        for (final t in _split(_tags.text)) {'name': t},
      ]
      ..['connection_type'] = _local ? 'local' : 'external'
      ..['auth_type'] = _authType
      ..['passthrough_params'] = _split(_passthrough.text);
    if (headers == null) {
      _c.config.remove('headers');
    } else {
      _c.config['headers'] = headers;
    }
    if (openAi) {
      _c.config['forward_cookies'] = _cookies;
      if (_provider.isEmpty) {
        _c.config.remove('provider');
      } else {
        _c.config['provider'] = _provider;
      }
      if (_azure) {
        _c.config
          ..['azure'] = true
          ..['api_version'] = _apiVersion.text.trim();
      } else {
        _c.config
          ..remove('azure')
          ..remove('api_version');
      }
      if (_responses) {
        _c.config['api_type'] = 'responses';
      } else {
        _c.config.remove('api_type');
      }
    }
    return true;
  }

  Future<void> _verify() async {
    if (!_apply()) return;
    setState(() => _checking = true);
    try {
      await ref
          .read(clientProvider)
          .send(
            'POST',
            '${widget.kind.base}/verify',
            body: {'url': _c.url, 'key': _c.key, 'config': _c.config},
          );
      if (mounted) _say(context, 'Connection works');
    } catch (e) {
      if (mounted) _say(context, 'It didn\'t answer: $e');
    }
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final openAi = widget.kind == openAiConnections;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.connection == null ? 'Add connection' : 'Edit connection',
        ),
        actions: [
          if (widget.connection != null)
            IconButton(
              tooltip: 'Delete',
              onPressed: () => Navigator.pop(context, 'delete'),
              icon: const Icon(Icons.delete_outline),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: () {
                if (_url.text.trim().isEmpty) {
                  _say(context, 'Enter the address');
                  return;
                }
                if (_apply()) Navigator.pop(context, _c);
              },
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'URL'),
            onChanged: (_) => setState(() {}),
          ),
          if (openAi)
            DropdownButtonFormField<String>(
              initialValue: _provider,
              decoration: const InputDecoration(labelText: 'Provider'),
              items: const [
                DropdownMenuItem(value: '', child: Text('Default')),
                DropdownMenuItem(value: 'azure', child: Text('Azure OpenAI')),
                DropdownMenuItem(value: 'llama.cpp', child: Text('llama.cpp')),
                DropdownMenuItem(value: 'lmstudio', child: Text('LM Studio')),
                DropdownMenuItem(value: 'litellm', child: Text('LiteLLM')),
              ],
              onChanged: (v) => setState(() => _provider = v ?? ''),
            ),
          if (openAi && _azure)
            TextField(
              controller: _apiVersion,
              decoration: const InputDecoration(labelText: 'API Version'),
            ),
          if (openAi)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('API type'),
              subtitle: Text(_responses ? 'Responses' : 'Chat Completions'),
              value: _responses,
              onChanged: (on) => setState(() => _responses = on),
            ),
          if (openAi)
            DropdownButtonFormField<String>(
              initialValue: _authType,
              decoration: const InputDecoration(labelText: 'Auth'),
              items: const [
                DropdownMenuItem(value: 'bearer', child: Text('Bearer key')),
                DropdownMenuItem(value: 'none', child: Text('None')),
                DropdownMenuItem(
                  value: 'session',
                  child: Text('The user\'s session'),
                ),
                DropdownMenuItem(
                  value: 'system_oauth',
                  child: Text('The user\'s OAuth sign-in'),
                ),
              ],
              onChanged: (v) => setState(() => _authType = v ?? 'bearer'),
            ),
          if (!openAi || _authType == 'bearer')
            TextField(
              controller: _key,
              obscureText: _hidden,
              decoration: InputDecoration(
                labelText: 'Key',
                suffixIcon: IconButton(
                  tooltip: _hidden ? 'Show' : 'Hide',
                  onPressed: () => setState(() => _hidden = !_hidden),
                  icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
                ),
              ),
            ),
          TextField(
            controller: _prefix,
            decoration: const InputDecoration(
              labelText: 'Prefix ID',
              helperText: 'Put before each model ID to tell servers apart',
            ),
          ),
          TextField(
            controller: _models,
            decoration: const InputDecoration(
              labelText: 'Model IDs (comma separated)',
              helperText: 'Empty offers every model the server has',
            ),
          ),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
              labelText: 'Tags (comma separated)',
            ),
          ),
          TextField(
            controller: _headers,
            minLines: 1,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Headers',
              helperText: 'JSON, sent with every request',
            ),
          ),
          TextField(
            controller: _passthrough,
            decoration: const InputDecoration(
              labelText: 'Passthrough params (comma separated)',
              helperText: 'Request fields sent to the server as they are',
            ),
          ),
          if (openAi)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Forward cookies'),
              subtitle: const Text(
                'Forward cookies from your Open WebUI request to this server.',
              ),
              value: _cookies,
              onChanged: (on) => setState(() => _cookies = on),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Local'),
            subtitle: const Text(
              'On this network, rather than an outside service',
            ),
            value: _local,
            onChanged: (on) => setState(() => _local = on),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _checking ? null : _verify,
            icon: _checking
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_tethering),
            label: const Text('Verify connection'),
          ),
        ],
      ),
    );
  }
}
