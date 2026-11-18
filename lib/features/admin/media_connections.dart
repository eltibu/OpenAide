/// Open WebUI 0.13.4's image and video connections: Admin Settings > Images
/// and > Videos now hold a list of servers (OpenAI-compatible, Gemini,
/// ComfyUI, AUTOMATIC1111; videos: OpenAI-compatible or OpenRouter), each
/// with its own models, sizes and access, instead of one engine.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';

/// Images or videos: where their connections live and what they can be.
enum MediaKind {
  images('IMAGE_CONNECTIONS', '/api/v1/images/connections/verify', [
    'openai',
    'gemini',
    'comfyui',
    'automatic1111',
  ]),
  videos('VIDEO_CONNECTIONS', '/api/v1/videos/connections/verify', ['openai']);

  const MediaKind(this.key, this.verifyPath, this.types);

  /// The setting holding the list.
  final String key;
  final String verifyPath;
  final List<String> types;
}

const mediaTypeLabels = {
  'openai': 'OpenAI compatible',
  'gemini': 'Gemini',
  'comfyui': 'ComfyUI',
  'automatic1111': 'AUTOMATIC1111',
};

/// Everyone may use it, as the web gives a connection made from the old
/// settings.
const publicMediaGrants = [
  {'principal_type': 'user', 'principal_id': '*', 'permission': 'read'},
];

/// A new connection, open to everyone (an empty access list would make it
/// admins-only).
Map<String, dynamic> newMediaConnection(MediaKind kind) => {
  'id': const Uuid().v4(),
  'name': '',
  'type': 'openai',
  'url': '',
  'key': '',
  'config': {
    'enable': true,
    'model_ids': <String>[],
    'access_grants': [
      for (final g in publicMediaGrants) {...g},
    ],
    'auth_type': 'bearer',
    if (kind == MediaKind.images)
      'capabilities': {'image_generation': true, 'image_edit': true},
    if (kind == MediaKind.videos) 'provider': '',
  },
};

/// Model ids typed as a comma or line separated list, without repeats.
List<String> parseModelIds(String text) {
  final out = <String>[];
  for (final part in text.split(RegExp(r'[,\n]'))) {
    final id = part.trim();
    if (id.isNotEmpty && !out.contains(id)) out.add(id);
  }
  return out;
}

/// Whether [grants] is exactly "everyone may use it".
bool isPublicMedia(Object? grants) =>
    grants is List &&
    grants.any(
      (g) =>
          g is Map && g['principal_type'] == 'user' && g['principal_id'] == '*',
    );

/// One line about a connection for the list: type, address and models.
String mediaConnectionSummary(Map c) {
  final config = (c['config'] as Map?) ?? const {};
  final models = (config['model_ids'] as List?) ?? const [];
  return [
    mediaTypeLabels['${c['type']}'] ?? '${c['type']}',
    if ('${c['url'] ?? ''}'.isNotEmpty) '${c['url']}',
    if (models.isNotEmpty)
      models.length == 1 ? '${models.first}' : '${models.length} models',
    if (config['enable'] == false) 'off',
    if (!isPublicMedia(config['access_grants']))
      (config['access_grants'] as List?)?.isNotEmpty == true
          ? 'some people'
          : 'admins only',
  ].join(' · ');
}

/// The list of connections; pops with the edited list.
class MediaConnectionsScreen extends StatefulWidget {
  const MediaConnectionsScreen({
    super.key,
    required this.kind,
    required this.connections,
  });

  final MediaKind kind;
  final List connections;

  @override
  State<MediaConnectionsScreen> createState() => _MediaConnectionsState();
}

class _MediaConnectionsState extends State<MediaConnectionsScreen> {
  late final List<Map<String, dynamic>> _list = [
    for (final c in widget.connections.whereType<Map>())
      jsonDecode(jsonEncode(c)) as Map<String, dynamic>,
  ];

  Future<void> _edit([int? index]) async {
    final start = index == null
        ? newMediaConnection(widget.kind)
        : _list[index];
    final res = await Navigator.push<Object>(
      context,
      MaterialPageRoute(
        builder: (_) => _MediaConnectionEditor(
          kind: widget.kind,
          connection: jsonDecode(jsonEncode(start)) as Map<String, dynamic>,
          isNew: index == null,
        ),
      ),
    );
    if (!mounted || res == null) return;
    setState(() {
      if (res == false && index != null) {
        _list.removeAt(index);
      } else if (res is Map<String, dynamic>) {
        index == null ? _list.add(res) : _list[index] = res;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final images = widget.kind == MediaKind.images;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _list);
      },
      child: Scaffold(
        appBar: AppBar(
          title: T(images ? 'Image connections' : 'Video connections'),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _edit,
          icon: const Icon(Icons.add),
          label: const T('Add connection'),
        ),
        body: _list.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: T(
                    images
                        ? 'No image connections yet. Add an OpenAI-compatible '
                              'server such as LiteLLM, Gemini, ComfyUI or '
                              'AUTOMATIC1111.'
                        : 'No video connections yet. Add OpenAI, LiteLLM or '
                              'OpenRouter.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  ListTile(
                    title: T(
                      'Changes are kept when you tap Save on the settings '
                      'page.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                  for (final (i, c) in _list.indexed)
                    ListTile(
                      leading: Icon(
                        images ? Icons.image_outlined : Icons.movie_outlined,
                      ),
                      title: Text(
                        '${c['name'] ?? ''}'.isEmpty
                            ? '${c['type']}'
                            : '${c['name']}',
                      ),
                      subtitle: Text(mediaConnectionSummary(c)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _edit(i),
                    ),
                ],
              ),
      ),
    );
  }
}

/// One connection; pops with it, or false to remove it.
class _MediaConnectionEditor extends ConsumerStatefulWidget {
  const _MediaConnectionEditor({
    required this.kind,
    required this.connection,
    required this.isNew,
  });

  final MediaKind kind;
  final Map<String, dynamic> connection;
  final bool isNew;

  @override
  ConsumerState<_MediaConnectionEditor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_MediaConnectionEditor> {
  late final Map<String, dynamic> _c = widget.connection;
  late final Map<String, dynamic> _cfg = ((_c['config'] as Map?) ?? {})
      .cast<String, dynamic>();
  late final _models = TextEditingController(
    text: ((_cfg['model_ids'] as List?) ?? const []).join(', '),
  );
  bool _verifying = false;
  List<String> _found = const [];

  bool get _images => widget.kind == MediaKind.images;
  String get _type => '${_c['type'] ?? 'openai'}';

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Map<String, dynamic> _result() {
    _cfg['model_ids'] = parseModelIds(_models.text);
    // Only OpenAI-compatible connections sign in other ways than a key.
    if (_type != 'openai' &&
        !const {'none', 'bearer'}.contains(_cfg['auth_type'])) {
      _cfg['auth_type'] = 'bearer';
    }
    return {..._c, 'config': _cfg};
  }

  Future<void> _verify() async {
    setState(() => _verifying = true);
    try {
      final res = await ref
          .read(clientProvider)
          .send('POST', widget.kind.verifyPath, body: _result());
      final ids = [
        for (final m in (res is List ? res : const []).whereType<Map>())
          if (_images ? m['image'] != false : m['video'] != false) '${m['id']}',
      ];
      if (!mounted) return;
      setState(() => _found = ids);
      _say(
        ids.isEmpty
            ? tr('Connected')
            : '${tr('Connected')}: ${ids.length} ${tr('models')}',
      );
    } catch (e) {
      if (mounted) _say('${tr("Couldn't connect")}: $e');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  void _addModel(String id) {
    final ids = parseModelIds(_models.text);
    if (ids.contains(id)) return;
    setState(() => _models.text = [...ids, id].join(', '));
  }

  Widget _field(
    String label,
    Object? value,
    void Function(String) onChanged, {
    String? hint,
    bool secret = false,
    int lines = 1,
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
    child: TextFormField(
      initialValue: value == null ? '' : '$value',
      obscureText: secret,
      maxLines: secret ? 1 : lines,
      minLines: 1,
      keyboardType: number ? TextInputType.number : null,
      decoration: InputDecoration(
        labelText: tr(label),
        hintText: hint == null ? null : tr(hint),
        border: const OutlineInputBorder(),
      ),
      onChanged: onChanged,
    ),
  );

  String _jsonText(Object? v) => v is Map && v.isNotEmpty
      ? const JsonEncoder.withIndent('  ').convert(v)
      : v is String
      ? v
      : '';

  @override
  Widget build(BuildContext context) {
    final caps = ((_cfg['capabilities'] as Map?) ?? const {})
        .cast<String, dynamic>();
    final public = isPublicMedia(_cfg['access_grants']);
    final custom =
        !public && ((_cfg['access_grants'] as List?)?.isNotEmpty ?? false);
    return Scaffold(
      appBar: AppBar(
        title: T(widget.isNew ? 'Add connection' : 'Edit connection'),
        actions: [
          if (!widget.isNew)
            IconButton(
              tooltip: tr('Remove'),
              icon: const Icon(Icons.delete_outline),
              onPressed: () => Navigator.pop(context, false),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: () {
                if ('${_c['url'] ?? ''}'.trim().isEmpty) {
                  _say(tr('Add the address'));
                  return;
                }
                Navigator.pop(context, _result());
              },
              child: const T('Done'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SwitchListTile(
            title: const T('On'),
            value: _cfg['enable'] != false,
            onChanged: (v) => setState(() => _cfg['enable'] = v),
          ),
          _field('Name', _c['name'], (v) => _c['name'] = v.trim()),
          if (widget.kind.types.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: DropdownButtonFormField<String>(
                initialValue: widget.kind.types.contains(_type)
                    ? _type
                    : 'openai',
                decoration: InputDecoration(
                  labelText: tr('Type'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final t in widget.kind.types)
                    DropdownMenuItem(
                      value: t,
                      child: Text(mediaTypeLabels[t] ?? t),
                    ),
                ],
                onChanged: (v) => setState(() => _c['type'] = v ?? 'openai'),
              ),
            ),
          if (!_images)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: DropdownButtonFormField<String>(
                initialValue: _cfg['provider'] == 'openrouter'
                    ? 'openrouter'
                    : '',
                decoration: InputDecoration(
                  labelText: tr('Provider'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(value: '', child: T('OpenAI or LiteLLM')),
                  const DropdownMenuItem(
                    value: 'openrouter',
                    child: Text('OpenRouter'),
                  ),
                ],
                onChanged: (v) => setState(() => _cfg['provider'] = v ?? ''),
              ),
            ),
          _field(
            'URL',
            _c['url'],
            (v) => _c['url'] = v.trim(),
            hint: 'https://api.openai.com/v1',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: DropdownButtonFormField<String>(
              initialValue: _type == 'openai'
                  ? '${_cfg['auth_type'] ?? 'bearer'}'
                  : (_cfg['auth_type'] == 'none' ? 'none' : 'bearer'),
              decoration: InputDecoration(
                labelText: tr('Sign-in'),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(value: 'bearer', child: T('Key')),
                DropdownMenuItem(value: 'none', child: T('None')),
                if (_type == 'openai') ...[
                  DropdownMenuItem(
                    value: 'session',
                    child: T("The person's own session"),
                  ),
                  DropdownMenuItem(
                    value: 'system_oauth',
                    child: T("The person's single sign-on"),
                  ),
                  const DropdownMenuItem(
                    value: 'microsoft_entra_id',
                    child: Text('Microsoft Entra ID'),
                  ),
                ],
              ],
              onChanged: (v) =>
                  setState(() => _cfg['auth_type'] = v ?? 'bearer'),
            ),
          ),
          if (_cfg['auth_type'] == null || _cfg['auth_type'] == 'bearer')
            _field('Key', _c['key'], (v) => _c['key'] = v, secret: true),
          if (_images)
            SwitchListTile(
              title: const T('Makes pictures'),
              value: caps['image_generation'] != false,
              onChanged: (v) => setState(
                () => _cfg['capabilities'] = {...caps, 'image_generation': v},
              ),
            ),
          if (_images && _type != 'automatic1111')
            SwitchListTile(
              title: const T('Edits pictures'),
              value: caps['image_edit'] != false,
              onChanged: (v) => setState(
                () => _cfg['capabilities'] = {...caps, 'image_edit': v},
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: TextField(
              controller: _models,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: tr('Model IDs'),
                helperText: tr(
                  'Comma separated. Empty lists what the server offers.',
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (_found.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final id in _found)
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 16),
                      label: Text(id),
                      onPressed: () => _addModel(id),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: OutlinedButton.icon(
              onPressed: _verifying ? null : _verify,
              icon: _verifying
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering),
              label: const T('Check connection and list models'),
            ),
          ),
          _field(
            'Size',
            _cfg['size'],
            (v) => _cfg['size'] = v.trim(),
            hint: _images ? 'auto or 1024x1024' : '1280x720',
          ),
          if (_images && _type != 'automatic1111' && _type != 'gemini')
            _field(
              'Edit size',
              _cfg['edit_size'],
              (v) => _cfg['edit_size'] = v.trim(),
            ),
          if (_images && (_type == 'comfyui' || _type == 'automatic1111'))
            _field(
              'Steps',
              _cfg['steps'],
              (v) => _cfg['steps'] = int.tryParse(v.trim()),
              number: true,
            ),
          if (!_images)
            _field(
              'Length in seconds',
              _cfg['seconds'],
              (v) => _cfg['seconds'] = int.tryParse(v.trim()),
              number: true,
            ),
          if (_type == 'gemini')
            _field(
              'Endpoint method',
              _cfg['endpoint_method'],
              (v) => _cfg['endpoint_method'] = v.trim(),
              hint: 'predict or generateContent',
            ),
          if (_type == 'openai')
            _field(
              'API version',
              _cfg['api_version'],
              (v) => _cfg['api_version'] = v.trim(),
              hint: 'Only for Azure OpenAI',
            ),
          if (_type == 'comfyui') ...[
            _field(
              'Workflow (JSON)',
              _jsonText(_cfg['workflow']),
              (v) => _cfg['workflow'] = v,
              lines: 4,
            ),
            _field(
              'Edit workflow (JSON)',
              _jsonText(_cfg['edit_workflow']),
              (v) => _cfg['edit_workflow'] = v,
              lines: 4,
            ),
          ],
          _field(
            'Additional parameters (JSON)',
            _jsonText(_cfg['params']),
            (v) => _cfg['params'] = v.trim(),
            lines: 3,
          ),
          if (_type == 'openai')
            _field(
              'Headers (JSON)',
              _jsonText(_cfg['headers']),
              (v) => _cfg['headers'] = v.trim(),
              lines: 2,
            ),
          SwitchListTile(
            title: const T('Everyone can use it'),
            subtitle: T(
              custom
                  ? 'Shared with some people and groups (change it on the web).'
                  : public
                  ? 'Anyone with the permission can pick its models.'
                  : 'Only admins can use it.',
            ),
            value: public,
            onChanged: custom
                ? null
                : (v) => setState(
                    () => _cfg['access_grants'] = v
                        ? [
                            for (final g in publicMediaGrants) {...g},
                          ]
                        : <Map<String, dynamic>>[],
                  ),
          ),
        ],
      ),
    );
  }
}
