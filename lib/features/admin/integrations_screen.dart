/// Admin > Integrations: tool servers (OpenAPI or MCP) and terminal servers
/// everyone's chats can use. Each connection is edited as the server's own
/// map, so settings the app doesn't show are saved back untouched.
library;

import 'external_knowledge.dart';

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../server/server_page.dart';
import 'orchestrator_policy.dart';
import '../../core/i18n/app_strings.dart';

/// A connection as the web exports it: one item in a list, without who may
/// use it or the OAuth client the server registered.
String exportConnection(Map<String, dynamic> c) {
  final info = {...?(c['info'] as Map?)?.cast<String, dynamic>()}
    ..remove('oauth_client_info')
    ..remove('oauth_client_secret');
  return jsonEncode([
    {
      for (final k in [
        'type',
        'url',
        'spec_type',
        'spec',
        'path',
        'auth_type',
        'forward_cookies',
        'headers',
        'key',
      ])
        if (c[k] != null) k: c[k],
      'info': info,
    },
  ]);
}

/// Fills a connection from an exported file (a list, or one connection),
/// keeping who may use it. Throws [FormatException] when it isn't one.
void importConnection(Map<String, dynamic> c, String text) {
  var data = jsonDecode(text);
  if (data is List) data = data.isEmpty ? null : data.first;
  if (data is! Map) throw const FormatException('Not a connection');
  for (final k in [
    'type',
    'url',
    'spec_type',
    'spec',
    'path',
    'auth_type',
    'headers',
    'key',
  ]) {
    if (data[k] != null) c[k] = data[k];
  }
  c['forward_cookies'] = data['forward_cookies'] == true;
  final info = data['info'];
  if (info is Map) {
    c['info'] = {
      ...?(c['info'] as Map?)?.cast<String, dynamic>(),
      ...info.cast<String, dynamic>(),
    };
  }
  final config = data['config'];
  if (config is Map && config['enable'] != null) {
    c['config'] = {
      ...?(c['config'] as Map?)?.cast<String, dynamic>(),
      'enable': config['enable'],
    };
  }
}

/// A connection id as the web makes one from a name.
String slugId(String from) => from
    .toLowerCase()
    .replaceAll(RegExp(r'^https?://'), '')
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(text))));

const _everyone = {
  'principal_type': 'user',
  'principal_id': '*',
  'permission': 'read',
};

/// Whether everyone may use a connection; with no grants only admins can.
bool isPublicConnection(Map<String, dynamic> c) =>
    ((c['config'] as Map?)?['access_grants'] as List? ?? const []).any(
      (g) => g is Map && g['principal_id'] == '*',
    );

/// Sets who may use a connection, keeping any group grants it has.
void setPublicConnection(Map<String, dynamic> c, bool everyone) {
  final config = {...?(c['config'] as Map?)?.cast<String, dynamic>()};
  final grants = [
    for (final g in config['access_grants'] as List? ?? const [])
      if (!(g is Map && g['principal_id'] == '*')) g,
  ];
  if (everyone) grants.add(_everyone);
  config['access_grants'] = grants;
  c['config'] = config;
}

/// The two kinds of server this page lists.
class ServerKind {
  const ServerKind({
    required this.title,
    required this.path,
    required this.key,
    required this.blank,
    required this.enabled,
    required this.setEnabled,
    required this.label,
  });

  final String title;

  /// The admin config endpoint, read with GET and saved with POST.
  final String path;
  final String key;
  final Map<String, dynamic> Function() blank;
  final bool Function(Map<String, dynamic>) enabled;
  final void Function(Map<String, dynamic>, bool) setEnabled;
  final String Function(Map<String, dynamic>) label;
}

final toolServerKind = ServerKind(
  title: 'Tool servers',
  path: '/api/v1/configs/tool_servers',
  key: 'TOOL_SERVER_CONNECTIONS',
  blank: () => {
    'url': '',
    'path': 'openapi.json',
    'type': 'openapi',
    'auth_type': 'bearer',
    'key': '',
    'forward_cookies': false,
    'config': {
      'enable': true,
      'access_grants': [_everyone],
    },
    'info': {'id': '', 'name': '', 'description': ''},
  },
  enabled: (c) => (c['config'] as Map?)?['enable'] == true,
  setEnabled: (c, on) => c['config'] = {
    ...?(c['config'] as Map?)?.cast<String, dynamic>(),
    'enable': on,
  },
  label: (c) {
    final info = (c['info'] as Map?) ?? const {};
    final name = '${info['name'] ?? ''}';
    return name.isNotEmpty ? name : '${c['url'] ?? ''}';
  },
);

final terminalServerKind = ServerKind(
  title: 'Terminal servers',
  path: '/api/v1/configs/terminal_servers',
  key: 'TERMINAL_SERVER_CONNECTIONS',
  blank: () => {
    'id': '',
    'name': '',
    'enabled': true,
    'url': '',
    'path': '/openapi.json',
    'key': '',
    'auth_type': 'bearer',
    'forward_cookies': false,
    'config': {
      'access_grants': [_everyone],
    },
  },
  enabled: (c) => c['enabled'] != false,
  setEnabled: (c, on) => c['enabled'] = on,
  label: (c) {
    final name = '${c['name'] ?? ''}';
    return name.isNotEmpty ? name : '${c['url'] ?? ''}';
  },
);

class IntegrationsScreen extends StatelessWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: const T('Integrations'),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Tool servers'),
            Tab(text: 'Terminal servers'),
            Tab(text: 'Knowledge'),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          ServerList(kind: toolServerKind),
          ServerList(kind: terminalServerKind),
          ExternalKnowledgeScreen(embedded: true),
        ],
      ),
    ),
  );
}

class ServerList extends ConsumerStatefulWidget {
  const ServerList({super.key, required this.kind});
  final ServerKind kind;

  @override
  ConsumerState<ServerList> createState() => _ServerListState();
}

class _ServerListState extends ConsumerState<ServerList> {
  List<Map<String, dynamic>>? _list;
  Object? _error;
  bool _busy = false;

  ServerKind get _k => widget.kind;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(clientProvider).send('GET', _k.path) as Map;
      _list = [
        for (final c in res[_k.key] as List? ?? const [])
          if (c is Map) jsonDecode(jsonEncode(c)) as Map<String, dynamic>,
      ];
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  Future<void> _save(List<Map<String, dynamic>> list) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(clientProvider)
          .send('POST', _k.path, body: {_k.key: list});
    } catch (e) {
      if (mounted) _say(context, 'Not saved: $e');
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _edit([int? index]) async {
    final list = _list!;
    final start = index == null
        ? _k.blank()
        : jsonDecode(jsonEncode(list[index])) as Map<String, dynamic>;
    final result = await Navigator.push<Object>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ServerEditor(kind: _k, connection: start, isNew: index == null),
      ),
    );
    if (result == null) return;
    final next = [...list];
    if (result == ServerEditor.delete) {
      next.removeAt(index!);
    } else if (index == null) {
      next.add(result as Map<String, dynamic>);
    } else {
      next[index] = result as Map<String, dynamic>;
    }
    await _save(next);
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final muted = context.nexus.muted;
    if (list == null) {
      return Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Couldn\'t load ${_k.title.toLowerCase()}.\n$_error',
                ),
              )
            : const CircularProgressIndicator(),
      );
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: _k.key,
        onPressed: _busy ? null : _edit,
        icon: const Icon(Icons.add),
        label: const T('Add connection'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No ${_k.title.toLowerCase()} yet.',
                  style: TextStyle(color: muted),
                ),
              ),
            for (final (i, c) in list.indexed)
              ListTile(
                leading: Icon(
                  _k == toolServerKind
                      ? (c['type'] == 'mcp' ? Icons.hub_outlined : Icons.api)
                      : Icons.terminal,
                ),
                title: Text(_k.label(c), overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [
                    if (_k == toolServerKind)
                      c['type'] == 'mcp' ? 'MCP' : 'OpenAPI',
                    '${c['url'] ?? ''}',
                    isPublicConnection(c) ? 'everyone' : 'admins only',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted),
                ),
                onTap: _busy ? null : () => _edit(i),
                trailing: Switch(
                  value: _k.enabled(c),
                  onChanged: _busy
                      ? null
                      : (on) {
                          final next = [...list];
                          next[i] = {...c};
                          _k.setEnabled(next[i], on);
                          _save(next);
                        },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Edits one connection and pops it (or [delete]) back to the list.
class ServerEditor extends ConsumerStatefulWidget {
  const ServerEditor({
    super.key,
    required this.kind,
    required this.connection,
    required this.isNew,
  });

  static const delete = 'delete';

  final ServerKind kind;
  final Map<String, dynamic> connection;
  final bool isNew;

  @override
  ConsumerState<ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends ConsumerState<ServerEditor> {
  // A plain copy, so every part of it takes any value.
  late final Map<String, dynamic> _c =
      jsonDecode(jsonEncode(widget.connection)) as Map<String, dynamic>;
  bool _verifying = false;

  /// Bumped when an import replaces the fields, so they show the new values.
  int _form = 0;

  late final _policy = OrchestratorPolicy(id: '${_c['policy_id'] ?? ''}');
  String? _policyError;
  bool _policyLoading = false;
  bool _onlyIdle = true;
  bool _resetTerminals = false;
  bool _saving = false;

  bool get _orchestrator => !_tool && _c['server_type'] == 'orchestrator';

  @override
  void initState() {
    super.initState();
    if (_orchestrator && _policy.id.isNotEmpty && !widget.isNew) {
      _loadPolicy();
    }
  }

  Future<void> _loadPolicy() async {
    setState(() {
      _policyLoading = true;
      _policyError = null;
    });
    try {
      await _policy.load(ref.read(clientProvider), _c);
    } catch (e) {
      _policyError = '$e';
    }
    if (mounted) {
      setState(() {
        _policyLoading = false;
        _form++;
      });
    }
  }

  Future<void> _refreshTerminals() async {
    if (_policy.id.trim().isEmpty) return _say(context, 'Add a policy id');
    setState(() => _verifying = true);
    try {
      final n = await _policy.refresh(
        ref.read(clientProvider),
        _c,
        onlyIdle: _onlyIdle,
        reset: _resetTerminals,
      );
      if (mounted) _say(context, 'Refresh asked for $n terminal(s)');
    } catch (e) {
      if (mounted) _say(context, 'Couldn\'t refresh: $e');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  bool get _tool => widget.kind == toolServerKind;

  Map<String, dynamic> get _info =>
      (_c['info'] as Map<String, dynamic>?) ??
      (_c['info'] = <String, dynamic>{});
  Map<String, dynamic> get _config =>
      (_c['config'] as Map<String, dynamic>?) ??
      (_c['config'] = <String, dynamic>{});

  Widget _field(
    String label,
    Object? value,
    void Function(String) onChanged, {
    bool secret = false,
    String? hint,
    int? lines,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
    child: TextFormField(
      initialValue: value == null ? '' : '$value',
      obscureText: secret,
      minLines: lines,
      maxLines: lines == null ? 1 : null,
      decoration: InputDecoration(labelText: label, helperText: hint),
      onChanged: onChanged,
    ),
  );

  Widget _choice(
    String label,
    String value,
    Map<String, String> options,
    void Function(String) onChanged,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
    child: DropdownButtonFormField<String>(
      initialValue: options.containsKey(value) ? value : options.keys.first,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final o in options.entries)
          DropdownMenuItem(value: o.key, child: Text(o.value)),
      ],
      onChanged: (v) => setState(() => onChanged(v!)),
    ),
  );

  bool get _oauth =>
      _c['type'] == 'mcp' && '${_c['auth_type'] ?? ''}'.startsWith('oauth_2.1');

  /// A new MCP connection takes its id from its name, as on the web.
  void _ensureId() {
    if (_c['type'] == 'mcp' &&
        widget.isNew &&
        '${_info['id'] ?? ''}'.trim().isEmpty) {
      final slug = slugId('${_info['name'] ?? ''}');
      _info['id'] = slug.isEmpty
          ? 'mcp-${DateTime.now().millisecondsSinceEpoch}'
          : slug;
    }
  }

  Future<void> _register() async {
    final url = '${_c['url'] ?? ''}'.trim();
    if (url.isEmpty) return _say(context, 'Add the server\'s URL');
    final static = _c['auth_type'] == 'oauth_2.1_static';
    if (static &&
        ('${_info['oauth_client_id'] ?? ''}'.isEmpty ||
            '${_info['oauth_client_secret'] ?? ''}'.isEmpty)) {
      return _say(context, 'Add the client id and secret');
    }
    setState(_ensureId);
    final id = '${_info['id'] ?? ''}'.trim();
    if (id.isEmpty) return _say(context, 'Add an id to register');
    setState(() => _verifying = true);
    try {
      final scope = '${_info['oauth_scope'] ?? ''}';
      final res = await ref
          .read(clientProvider)
          .send(
            'POST',
            '/api/v1/configs/oauth/clients/register',
            query: {'type': 'mcp'},
            body: {
              'url': url,
              'client_id': id,
              if (scope.isNotEmpty) 'oauth_scope': scope,
              if (static) ...{
                'client_secret': _info['oauth_client_secret'],
                'oauth_server_url': _info['oauth_server_url'] ?? '',
              },
            },
          );
      _info['oauth_client_info'] = (res as Map?)?['oauth_client_info'];
      if (mounted) {
        _say(context, 'Registered. Save to keep it, and keep the id as it is.');
      }
    } catch (e) {
      if (mounted) _say(context, 'Registration failed: $e');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _authorize() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ServerPage(
          title: 'Sign in',
          path: '/oauth/clients/mcp:${_info['id']}/authorize',
          signIn: true,
        ),
      ),
    );
    if (ok == true && mounted) _say(context, 'Signed in');
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    try {
      importConnection(_c, utf8.decode(await picked.first.readAsBytes()));
      setState(() => _form++);
      if (mounted) _say(context, 'Imported');
    } catch (_) {
      if (mounted) _say(context, 'That isn\'t a connection file');
    }
  }

  Future<void> _export() async {
    final name = '${_info['id'] ?? ''}'.isNotEmpty
        ? _info['id']
        : '${_info['name'] ?? ''}'.isNotEmpty
        ? _info['name']
        : 'export';
    await FilePicker.saveFile(
      fileName: 'tool-server-$name.json',
      bytes: utf8.encode(exportConnection(_c)),
    );
  }

  Future<void> _verify() async {
    setState(() => _verifying = true);
    try {
      final res = await ref
          .read(clientProvider)
          .send('POST', '${widget.kind.path}/verify', body: _c);
      if (!mounted) return;
      final type = res is Map ? res['type'] : null;
      if (!_tool && type == 'orchestrator') {
        _c['server_type'] = 'orchestrator';
        if (_policy.id.isEmpty) {
          final from = '${_c['id'] ?? ''}'.isNotEmpty ? _c['id'] : _c['name'];
          _policy.id = slugId('${from ?? ''}');
          if (_policy.id.isEmpty) _policy.id = 'default';
          _form++;
        }
      } else if (!_tool && type == 'terminal') {
        _c['server_type'] = 'terminal';
      }
      _say(
        context,
        type == 'orchestrator'
            ? 'Connected (Orchestrator)'
            : type == 'terminal'
            ? 'Connected (Terminal)'
            : 'Connected',
      );
    } catch (e) {
      if (mounted) _say(context, 'Couldn\'t connect: $e');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _done() async {
    if (_saving) return;
    if ('${_c['url'] ?? ''}'.trim().isEmpty) {
      _say(context, 'Add the server\'s URL');
      return;
    }
    _c['url'] = '${_c['url']}'.trim();
    if (_tool && _c['type'] != 'mcp') {
      _c['url'] = '${_c['url']}'.replaceAll(RegExp(r'/$'), '');
    }
    if (!_tool && '${_c['id'] ?? ''}'.isEmpty) {
      // The web's id for a new terminal: from its name, or its address.
      final from = '${_c['name'] ?? ''}'.isNotEmpty ? _c['name'] : _c['url'];
      _c['id'] = slugId('$from');
    }
    if (_tool) {
      _ensureId();
      final id = '${_info['id'] ?? ''}';
      if (id.contains(':') || id.contains('|')) {
        _say(context, 'The id can\'t contain ":" or "|"');
        return;
      }
      if (_oauth && _info['oauth_client_info'] == null) {
        _say(context, 'Register the OAuth client first');
        return;
      }
      if (_c['spec_type'] == 'json') {
        try {
          _c['spec'] = const JsonEncoder.withIndent('  ')
              .convert(jsonDecode('${_c['spec'] ?? ''}'));
        } catch (_) {
          _say(context, 'The JSON spec isn\'t valid JSON');
          return;
        }
      }
    }
    if (!_tool) {
      _c['url'] = '${_c['url']}'.replaceAll(RegExp(r'/$'), '');
      _c['key'] = '${_c['key'] ?? ''}'.trim();
    }
    if (_orchestrator && _policy.id.trim().isNotEmpty) {
      if (_policyLoading) return _say(context, 'The policy is still loading');
      if (_policyError != null) {
        return _say(context, 'Couldn\'t load the policy: $_policyError');
      }
      _policy.id = _policy.id.trim();
      setState(() => _saving = true);
      try {
        await _policy.save(ref.read(clientProvider), _c);
      } catch (e) {
        if (mounted) {
          setState(() => _saving = false);
          _say(context, 'Policy not saved: $e');
        }
        return;
      }
      _c['policy_id'] = _policy.id;
    } else if (!_tool) {
      _c.remove('policy_id');
      _config.remove('contexts');
    }
    if (mounted) Navigator.pop(context, _c);
  }

  List<Widget> _orchestratorFields(Color muted) {
    final p = _policy;
    return [
      const Divider(),
      ListTile(
        title: const T('Orchestrator'),
        subtitle: T(
          'Each person gets their own terminal, made from this policy.',
          style: TextStyle(color: muted),
        ),
        trailing: _policyLoading
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      ),
      if (_policyError != null)
        ListTile(
          leading: const Icon(Icons.error_outline),
          title: Text('Couldn\'t load the policy: $_policyError'),
          trailing: TextButton(onPressed: _loadPolicy, child: const T('Retry')),
        ),
      _choice('Chat', contextMode(_config, 'chat'), const {
        'default': 'One terminal per person',
        'chat_id': 'One terminal per chat',
        'off': 'Off in chats',
      }, (v) => setContexts(_config, v, contextMode(_config, 'automation'))),
      _choice('Automation', contextMode(_config, 'automation'), const {
        'default': 'One terminal per person',
        'automation_id': 'One terminal per automation',
        'off': 'Off in automations',
      }, (v) => setContexts(_config, contextMode(_config, 'chat'), v)),
      _field('Policy id', p.id, (v) => p.id = v),
      _field(
        'Image',
        p.image,
        (v) => p.image = v,
        hint: 'Empty uses the orchestrator\'s default',
      ),
      Row(
        children: [
          Expanded(child: _field('CPU', p.cpu, (v) => p.cpu = v)),
          Expanded(child: _field('Memory', p.memory, (v) => p.memory = v)),
        ],
      ),
      _choice('Storage', p.persistent ? 'persistent' : 'ephemeral', const {
        'ephemeral': 'Ephemeral (lost on restart)',
        'persistent': 'Persistent',
      }, (v) => p.persistent = v == 'persistent'),
      if (p.persistent)
        _field('Storage size', p.storageSize, (v) => p.storageSize = v),
      _field(
        'Idle timeout (minutes)',
        p.idleMinutes,
        (v) => p.idleMinutes = int.tryParse(v.trim()) ?? 0,
        hint: '0 keeps terminals running',
      ),
      _field(
        'Environment',
        p.env,
        (v) => p.env = v,
        hint: 'One KEY=value per line',
        lines: 2,
      ),
      _field(
        'Lifecycle JSON',
        p.lifecycle,
        (v) => p.lifecycle = v,
        hint: 'Hooks the orchestrator runs, as a JSON object',
        lines: 3,
      ),
      if (!widget.isNew) ...[
        SwitchListTile(
          title: const T('Only idle terminals'),
          value: _onlyIdle,
          onChanged: (on) => setState(() => _onlyIdle = on),
        ),
        SwitchListTile(
          title: const T('Reset their files'),
          subtitle: const T('Start from a clean image'),
          value: _resetTerminals,
          onChanged: (on) => setState(() => _resetTerminals = on),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: OutlinedButton.icon(
            onPressed: _verifying ? null : _refreshTerminals,
            icon: const Icon(Icons.restart_alt),
            label: Text(_verifying ? 'Refreshing...' : 'Refresh terminals'),
          ),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final auth = '${_c['auth_type'] ?? (_tool ? 'none' : 'bearer')}';
    final mcp = _c['type'] == 'mcp';
    final headers = _c['headers'];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'Add connection' : 'Edit connection'),
        actions: [
          if (!widget.isNew)
            IconButton(
              tooltip: tr('Delete'),
              onPressed: () => Navigator.pop(context, ServerEditor.delete),
              icon: const Icon(Icons.delete_outline),
            ),
          if (_tool)
            PopupMenuButton<String>(
              onSelected: (v) => v == 'import' ? _import() : _export(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'import', child: T('Import')),
                PopupMenuItem(value: 'export', child: T('Export')),
              ],
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _done,
              child: const T('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        key: ValueKey(_form),
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          if (_tool)
            _choice('Type', mcp ? 'mcp' : 'openapi', const {
              'openapi': 'OpenAPI',
              'mcp': 'MCP (streamable HTTP)',
            }, (v) => _c['type'] = v),
          _field('URL', _c['url'], (v) => _c['url'] = v),
          if (_tool && !mcp)
            _choice('OpenAPI spec', '${_c['spec_type'] ?? 'url'}', const {
              'url': 'From a path or URL',
              'json': 'Pasted JSON',
            }, (v) => _c['spec_type'] = v),
          if (!mcp && _c['spec_type'] == 'json')
            _field('Spec JSON', _c['spec'], (v) => _c['spec'] = v, lines: 4)
          else if (!mcp)
            _field(
              _tool ? 'Spec path' : 'Spec path',
              _c['path'],
              (v) => _c['path'] = v,
              hint: 'A path on the server, or a full URL',
            ),
          _choice('Auth', auth, {
            'none': 'None',
            'bearer': 'Bearer key',
            'session': 'Your sign-in session',
            'system_oauth': 'Your OAuth sign-in',
            if (_tool && mcp) 'oauth_2.1': 'OAuth 2.1',
            if (_tool && mcp) 'oauth_2.1_static': 'OAuth 2.1 (static client)',
          }, (v) => _c['auth_type'] = v),
          if (auth == 'bearer')
            _field('Key', _c['key'], (v) => _c['key'] = v, secret: true),
          if (_oauth) ...[
            if (auth == 'oauth_2.1_static') ...[
              _field(
                'Client ID',
                _info['oauth_client_id'],
                (v) => _info['oauth_client_id'] = v,
              ),
              _field(
                'Client secret',
                _info['oauth_client_secret'],
                (v) => _info['oauth_client_secret'] = v,
                secret: true,
              ),
              _field(
                'Authorization server URL',
                _info['oauth_server_url'],
                (v) => _info['oauth_server_url'] = v,
                hint: 'Empty finds it from the server',
              ),
            ],
            _field(
              'Scope',
              _info['oauth_scope'],
              (v) => _info['oauth_scope'] = v,
              hint: 'Empty uses the scopes the server lists',
            ),
            _choice(
              'Resource parameter',
              '${_info['oauth_resource_parameter'] ?? 'auto'}',
              const {'auto': 'Automatic', 'include': 'Include', 'omit': 'Omit'},
              (v) => _info['oauth_resource_parameter'] = v,
            ),
            ListTile(
              leading: Icon(
                _info['oauth_client_info'] != null
                    ? Icons.verified_outlined
                    : Icons.app_registration,
              ),
              title: Text(
                _info['oauth_client_info'] != null
                    ? 'OAuth client registered'
                    : 'OAuth client not registered yet',
              ),
              subtitle: Text(
                widget.isNew
                    ? 'Register, save, then open it again to sign in.'
                    : 'Sign in once so the tools can act for you.',
                style: TextStyle(color: muted),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _verifying ? null : _register,
                    child: Text(
                      _info['oauth_client_info'] != null
                          ? 'Register again'
                          : 'Register client',
                    ),
                  ),
                  if (!widget.isNew && _info['oauth_client_info'] != null)
                    FilledButton.tonal(
                      onPressed: _authorize,
                      child: const T('Sign in'),
                    ),
                ],
              ),
            ),
          ],
          if (_tool)
            _field(
              'Headers',
              headers is Map ? jsonEncode(headers) : headers,
              (v) {
                try {
                  _c['headers'] = v.trim().isEmpty ? null : jsonDecode(v);
                } catch (_) {
                  _c['headers'] = v;
                }
              },
              hint: 'JSON, sent with every call',
              lines: 1,
            ),
          SwitchListTile(
            title: const T('Forward cookies'),
            subtitle: const T(
              'Forward cookies from your Open WebUI request to this server.',
            ),
            value: _c['forward_cookies'] == true,
            onChanged: (on) => setState(() => _c['forward_cookies'] = on),
          ),
          const Divider(),
          if (_tool) ...[
            _field('Id', _info['id'], (v) => _info['id'] = v),
            _field('Name', _info['name'], (v) => _info['name'] = v),
            _field(
              'Description',
              _info['description'],
              (v) => _info['description'] = v,
              lines: 1,
            ),
            _field(
              'Function name filter',
              _config['function_name_filter_list'],
              (v) => _config['function_name_filter_list'] = v,
              hint: 'Comma-separated tool names to allow; empty allows all',
            ),
          ] else ...[
            _field('Name', _c['name'], (v) => _c['name'] = v),
            _field(
              'Id',
              _c['id'],
              (v) => _c['id'] = v,
              hint: widget.isNew ? 'Made from the name if left empty' : null,
            ),
            SwitchListTile(
              title: const T('Working directory'),
              subtitle: const T(
                'Include the current directory in tool instructions.',
              ),
              value: _config['working_directory_context'] != false,
              onChanged: (on) =>
                  setState(() => _config['working_directory_context'] = on),
            ),
            SwitchListTile(
              title: const T('Always list shell tools'),
              subtitle: const T(
                'Keep tools listed even while your shell is closed.',
              ),
              value: _config['user_shell_tools'] == 'always',
              onChanged: (on) => setState(
                () => _config['user_shell_tools'] = on ? 'always' : 'auto',
              ),
            ),
            _choice(
              'Chat uploads',
              '${_config['chat_uploads'] ?? 'default'}',
              const {
                'default': 'As usual',
                'filesystem': 'Into the terminal\'s files',
              },
              (v) => _config['chat_uploads'] = v,
            ),
          ],
          if (_orchestrator) ..._orchestratorFields(muted),
          SwitchListTile(
            title: const T('Everyone can use it'),
            subtitle: const T('Off: only admins'),
            value: isPublicConnection(_c),
            onChanged: (on) => setState(() => setPublicConnection(_c, on)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: OutlinedButton.icon(
              onPressed: _verifying ? null : _verify,
              icon: _verifying
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering),
              label: Text(
                _oauth ? 'Check OAuth discovery' : 'Check connection',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
