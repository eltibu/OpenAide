/// Admin > Integrations > Knowledge: knowledge bases that live in another
/// vector database (Qdrant, Milvus or pgvector). Each one is tested with a
/// query before it is saved, as on the web.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../../core/i18n/app_strings.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(text))));

const _base = '/api/v1/knowledge/external';

/// The field names each kind of database uses by default.
Map<String, String> externalSchemaDefaults(String provider) =>
    switch (provider) {
      'milvus' => {
        'content': 'data.text',
        'vector': 'vector',
        'metadata': 'metadata',
        'documentId': 'id',
        'table': 'document_chunk',
        'collection': 'collection_name',
      },
      'pgvector' => {
        'content': 'text',
        'vector': 'vector',
        'metadata': 'vmetadata',
        'documentId': 'id',
        'table': 'document_chunk',
        'collection': 'collection_name',
      },
      _ => {
        'content': 'payload.text',
        'vector': '',
        'metadata': 'payload.metadata',
        'documentId': 'id',
        'table': 'document_chunk',
        'collection': 'collection_name',
      },
    };

/// The form's values, as the server takes them.
class ExternalSourceForm {
  ExternalSourceForm({
    this.provider = 'qdrant',
    this.name = '',
    this.description = '',
    this.endpoint = '',
    this.apiKey = '',
    this.timeout = 30,
    this.dbName = '',
    this.sourceName = '',
    Map<String, String>? fields,
    this.enabled = true,
    this.editing = false,
  }) : fields = fields ?? externalSchemaDefaults(provider);

  String provider, name, description, endpoint, apiKey, dbName, sourceName;
  int timeout;
  Map<String, String> fields;
  bool enabled;

  /// An existing connection keeps its key unless a new one is typed.
  bool editing;

  Map<String, dynamic> connection() => {
    'name': name.trim().isNotEmpty
        ? name.trim()
        : sourceName.trim().isNotEmpty
        ? sourceName.trim()
        : 'External Knowledge Source',
    'provider': provider,
    'endpoint': endpoint.trim(),
    'auth_config': provider == 'pgvector'
        ? {}
        : apiKey.isNotEmpty
        ? {'type': 'bearer', 'api_key': apiKey}
        : editing
        ? null
        : {},
    'config': {
      'timeout': timeout,
      if (provider == 'milvus' && dbName.trim().isNotEmpty)
        'db_name': dbName.trim(),
    },
    'capabilities': {'retrieve': true},
    'enabled': enabled,
  };

  Map<String, dynamic> source() {
    String f(String k) => (fields[k] ?? '').trim();
    return {
      'type': 'collection',
      'name': sourceName.trim(),
      'config': {
        'content_field': f('content'),
        if (f('vector').isNotEmpty) 'vector_field': f('vector'),
        if (f('metadata').isNotEmpty) 'metadata_field': f('metadata'),
        if (f('documentId').isNotEmpty) 'document_id_field': f('documentId'),
        if (provider == 'pgvector') ...{
          'table_name': f('table'),
          'collection_field': f('collection'),
        },
      },
    };
  }

  /// What's missing before a test can run, or null.
  String? testProblem(String query) {
    if (endpoint.trim().isEmpty) return 'Fill in the endpoint';
    if (sourceName.trim().isEmpty) return 'Fill in the collection';
    if ((fields['content'] ?? '').trim().isEmpty) {
      return 'Fill in the content field';
    }
    if (provider != 'qdrant' && (fields['vector'] ?? '').trim().isEmpty) {
      return 'Fill in the vector field';
    }
    if (provider == 'pgvector' &&
        ((fields['table'] ?? '').trim().isEmpty ||
            (fields['collection'] ?? '').trim().isEmpty)) {
      return 'Fill in the table and collection field';
    }
    if (query.trim().isEmpty) return 'Type a test query';
    return null;
  }
}

class ExternalKnowledgeScreen extends ConsumerStatefulWidget {
  const ExternalKnowledgeScreen({super.key, this.embedded = false});

  /// Inside another page's tabs: no title bar of its own.
  final bool embedded;

  @override
  ConsumerState<ExternalKnowledgeScreen> createState() =>
      _ExternalKnowledgeState();
}

class _ExternalKnowledgeState extends ConsumerState<ExternalKnowledgeScreen> {
  List<Map<String, dynamic>> _connections = [];
  List<Map<String, dynamic>>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(clientProvider);
    try {
      final res = await Future.wait([
        client.send('GET', '$_base/connections'),
        client.send(
          'GET',
          '/api/v1/knowledge/search',
          query: {'source': 'external', 'page': '1'},
        ),
      ]);
      List<Map<String, dynamic>> items(Object? r) => [
        for (final x in (r is Map ? r['items'] : r) as List? ?? const [])
          if (x is Map) x.cast<String, dynamic>(),
      ];
      _connections = items(res[0]);
      _items = items(res[1]);
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  Map<String, dynamic>? _connectionFor(Map item) {
    final id = ((item['meta'] as Map?)?['external'] as Map?)?['connection_id'];
    return _connections.where((c) => c['id'] == id).firstOrNull;
  }

  Future<void> _toggle(Map<String, dynamic> c) async {
    try {
      await ref
          .read(clientProvider)
          .send(
            'PATCH',
            '$_base/connections/${c['id']}',
            body: {
              'name': c['name'],
              'provider': c['provider'],
              'endpoint': c['endpoint'],
              'auth_config': null,
              'config': c['config'] ?? {},
              'capabilities': c['capabilities'] ?? {'retrieve': true},
              'enabled': c['enabled'] == false,
            },
          );
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    _load();
  }

  Future<void> _edit([Map<String, dynamic>? item]) async {
    final c = item == null ? null : _connectionFor(item);
    ExternalSourceForm? form;
    if (item != null && c != null) {
      final source = ((item['meta'] as Map?)?['external'] as Map?)?['source'];
      final config = (source as Map?)?['config'] as Map? ?? const {};
      final provider = '${c['provider'] ?? 'qdrant'}';
      final d = externalSchemaDefaults(provider);
      form = ExternalSourceForm(
        provider: provider,
        name: '${item['name'] ?? ''}',
        description: '${item['description'] ?? ''}',
        endpoint: '${c['endpoint'] ?? ''}',
        timeout: ((c['config'] as Map?)?['timeout'] as num?)?.toInt() ?? 30,
        dbName: '${(c['config'] as Map?)?['db_name'] ?? ''}',
        sourceName: '${source?['name'] ?? ''}',
        fields: {
          'content': '${config['content_field'] ?? d['content']}',
          'vector': '${config['vector_field'] ?? d['vector']}',
          'metadata': '${config['metadata_field'] ?? d['metadata']}',
          'documentId': '${config['document_id_field'] ?? d['documentId']}',
          'table': '${config['table_name'] ?? d['table']}',
          'collection': '${config['collection_field'] ?? d['collection']}',
        },
        enabled: c['enabled'] != false,
        editing: true,
      );
    }
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _SourceEditor(
          form: form ?? ExternalSourceForm(),
          knowledgeId: item?['id'] as String?,
          connectionId: c?['id'] as String?,
        ),
      ),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(title: const T('External knowledge')),
      floatingActionButton: items == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _edit,
              icon: const Icon(Icons.add),
              label: const T('Add Connection'),
            ),
      body: items == null
          ? Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text("Couldn't load them.\n$_error"),
                    )
                  : const CircularProgressIndicator(),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 88),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: T(
                      'Knowledge bases kept in your own Qdrant, Milvus or '
                      'pgvector database. Experimental on the server.',
                      style: TextStyle(color: muted),
                    ),
                  ),
                  if (items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: T(
                        'No external knowledge sources configured.',
                        style: TextStyle(color: muted),
                      ),
                    ),
                  for (final item in items)
                    Builder(
                      builder: (context) {
                        final c = _connectionFor(item);
                        final ext =
                            (item['meta'] as Map?)?['external'] as Map? ??
                            const {};
                        return ListTile(
                          leading: const Icon(Icons.storage_outlined),
                          title: Text('${item['name']}'),
                          subtitle: Text(
                            [
                              '${ext['provider'] ?? c?['provider'] ?? ''}',
                              if ((ext['source'] as Map?)?['name'] != null)
                                '${(ext['source'] as Map)['name']}',
                            ].join(' · '),
                            style: TextStyle(color: muted),
                          ),
                          onTap: c == null ? null : () => _edit(item),
                          trailing: c == null
                              ? null
                              : Switch(
                                  value: c['enabled'] != false,
                                  onChanged: (_) => _toggle(c),
                                ),
                        );
                      },
                    ),
                ],
              ),
            ),
    );
  }
}

class _SourceEditor extends ConsumerStatefulWidget {
  const _SourceEditor({
    required this.form,
    this.knowledgeId,
    this.connectionId,
  });
  final ExternalSourceForm form;
  final String? knowledgeId, connectionId;

  @override
  ConsumerState<_SourceEditor> createState() => _SourceEditorState();
}

class _SourceEditorState extends ConsumerState<_SourceEditor> {
  late final ExternalSourceForm _f = widget.form;
  final _query = TextEditingController();
  List<String>? _results;
  bool _busy = false;

  bool get _editing => widget.knowledgeId != null;

  void _changed() => setState(() => _results = null);

  Widget _field(
    String label,
    String value,
    void Function(String) set, {
    String? hint,
    bool secret = false,
  }) => TextFormField(
    initialValue: value,
    obscureText: secret,
    decoration: InputDecoration(labelText: label, hintText: hint),
    onChanged: (v) {
      set(v);
      _changed();
    },
  );

  Future<void> _test() async {
    final why = _f.testProblem(_query.text);
    if (why != null) return _say(context, why);
    setState(() => _busy = true);
    try {
      final res =
          await ref
                  .read(clientProvider)
                  .send(
                    'POST',
                    '$_base/source/test',
                    body: {
                      'connection_id': ?widget.connectionId,
                      'connection': _f.connection(),
                      'source': _f.source(),
                      'query': _query.text,
                      'count': 5,
                    },
                  )
              as Map?;
      final docs = [
        for (final d in res?['documents'] as List? ?? const []) '$d',
      ];
      if (!mounted) return;
      setState(() => _results = docs);
      _say(
        context,
        docs.isEmpty ? 'Test returned no results.' : 'Test succeeded.',
      );
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    if (_f.name.trim().isEmpty) return _say(context, 'Give it a name');
    if (_results?.isNotEmpty != true) {
      return _say(context, 'Test the source before saving it.');
    }
    setState(() => _busy = true);
    final body = {
      'name': _f.name,
      'description': _f.description,
      'connection': _f.connection(),
      'source': _f.source(),
      'test_query': _query.text,
      'test_count': 5,
    };
    try {
      final client = ref.read(clientProvider);
      if (_editing) {
        await client.send(
          'PATCH',
          '$_base/source/${widget.knowledgeId}',
          body: body,
        );
      } else {
        await client.send(
          'POST',
          '$_base/source/create',
          body: {...body, 'access_grants': []},
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        _say(context, '$e');
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final fields = _f.fields;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _editing ? 'Edit Knowledge Connection' : 'Add Knowledge Connection',
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy || _results?.isNotEmpty != true ? null : _save,
              child: Text(_editing ? 'Save' : 'Create'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          _field(
            'Name',
            _f.name,
            (v) => _f.name = v,
            hint: 'Research Knowledge',
          ),
          _field('Description', _f.description, (v) => _f.description = v),
          const SizedBox(height: 12),
          T('Provider', style: TextStyle(color: muted)),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'qdrant', label: T('Qdrant')),
              ButtonSegment(value: 'milvus', label: T('Milvus')),
              ButtonSegment(value: 'pgvector', label: T('pgvector')),
            ],
            selected: {_f.provider},
            onSelectionChanged: _editing
                ? null
                : (v) => setState(() {
                    _f.provider = v.first;
                    _f.fields = externalSchemaDefaults(v.first);
                    _results = null;
                  }),
          ),
          // Keyed by provider so a switch shows its own defaults.
          KeyedSubtree(
            key: ValueKey(_f.provider),
            child: Column(
              children: [
                _field(
                  'Endpoint',
                  _f.endpoint,
                  (v) => _f.endpoint = v,
                  hint: switch (_f.provider) {
                    'pgvector' => 'postgresql://user:password@host:5432/db',
                    'milvus' => 'http://milvus.example.com:19530',
                    _ => 'https://qdrant.example.com',
                  },
                ),
                _field(
                  'Timeout',
                  '${_f.timeout}',
                  (v) => _f.timeout = int.tryParse(v) ?? 30,
                ),
                if (_f.provider != 'pgvector')
                  _field(
                    'API Key / Token',
                    '',
                    (v) => _f.apiKey = v,
                    hint: _f.editing
                        ? 'Leave empty to keep the saved one'
                        : null,
                    secret: true,
                  ),
                if (_f.provider == 'milvus')
                  _field(
                    'Database',
                    _f.dbName,
                    (v) => _f.dbName = v,
                    hint: 'Default',
                  ),
                _field('Collection', _f.sourceName, (v) => _f.sourceName = v),
                if (_f.provider == 'pgvector') ...[
                  _field(
                    'Table',
                    fields['table'] ?? '',
                    (v) => fields['table'] = v,
                  ),
                  _field(
                    'Collection Field',
                    fields['collection'] ?? '',
                    (v) => fields['collection'] = v,
                  ),
                ],
                _field(
                  'Content Field',
                  fields['content'] ?? '',
                  (v) => fields['content'] = v,
                ),
                _field(
                  'Vector Field',
                  fields['vector'] ?? '',
                  (v) => fields['vector'] = v,
                  hint: _f.provider == 'qdrant' ? 'Optional' : null,
                ),
                _field(
                  'Metadata Field',
                  fields['metadata'] ?? '',
                  (v) => fields['metadata'] = v,
                ),
                _field(
                  'Document ID Field',
                  fields['documentId'] ?? '',
                  (v) => fields['documentId'] = v,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  decoration: InputDecoration(labelText: tr('Test query')),
                  onChanged: (_) => _changed(),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _busy ? null : _test,
                child: const T('Test'),
              ),
            ],
          ),
          if (_results != null)
            for (final d in _results!.take(5))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  d,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted, fontSize: 13),
                ),
              ),
        ],
      ),
    );
  }
}
