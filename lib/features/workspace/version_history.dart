/// Versions of a model, prompt, tool, skill or function, as the web's
/// history panel: every saved version, what it held, and which one is in
/// use (production), with a way to put an older one back or delete it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/compare_text.dart';

/// Where one kind's history lives on the server.
class HistoryPaths {
  HistoryPaths(this.kind, this.id);
  final String kind;
  final String id;

  String get _seg => Uri.encodeComponent(id);

  String get _base => switch (kind) {
    'model' => '/api/v1/models/model',
    'prompt' => '/api/v1/prompts/id/$_seg',
    'tool' => '/api/v1/tools/id/$_seg',
    'skill' => '/api/v1/skills/id/$_seg',
    'function' => '/api/v1/functions/id/$_seg',
    _ => throw ArgumentError(kind),
  };

  /// Models name themselves in the query; the rest in the path.
  Map<String, String> get _q => kind == 'model' ? {'id': id} : const {};

  /// [page] counts from 1; prompts count theirs from 0.
  (String, Map<String, String>) list(int page) => (
    '$_base/history',
    {..._q, 'page': '${kind == 'prompt' ? page - 1 : page}'},
  );
  (String, Map<String, String>) entry(String v) =>
      ('$_base/history/${Uri.encodeComponent(v)}', _q);
  (String, Map<String, String>) production() => ('$_base/update/version', _q);
  String get current => kind == 'model' ? '$_base?id=$_seg' : _base;
}

/// The text worth reading in a snapshot: code for tools and functions, the
/// prompt or skill's content, otherwise the whole snapshot.
String snapshotText(Map? snapshot) {
  if (snapshot == null) return '';
  for (final k in ['content']) {
    final v = snapshot[k];
    if (v is String && v.isNotEmpty) return v;
  }
  return const JsonEncoder.withIndent('  ').convert(snapshot);
}

class VersionHistoryScreen extends ConsumerStatefulWidget {
  const VersionHistoryScreen({
    super.key,
    required this.kind,
    required this.id,
    required this.name,
  });
  final String kind, id, name;

  @override
  ConsumerState<VersionHistoryScreen> createState() => _VersionHistoryState();
}

class _VersionHistoryState extends ConsumerState<VersionHistoryScreen> {
  late final _paths = HistoryPaths(widget.kind, widget.id);
  OpenWebUiClient get _client => ref.read(clientProvider);
  List<Map<String, dynamic>>? _list;
  String? _current;
  Object? _error;
  bool _more = true;
  bool _busy = false;
  int _page = 1;

  /// Whether anything changed, so the editor reloads.
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _load({bool next = false}) async {
    try {
      if (!next) {
        _page = 1;
        final now = await _client.send('GET', _paths.current);
        _current = (now as Map?)?['version_id']?.toString();
      }
      final (path, query) = _paths.list(_page);
      final res = await _client.send('GET', path, query: query);
      final items = [
        for (final e in res as List? ?? const [])
          if (e is Map) e.cast<String, dynamic>(),
      ];
      _list = [if (next) ...?_list, ...items];
      _more = items.isNotEmpty;
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  Future<Map<String, dynamic>?> _snapshot(String v) async {
    final (path, query) = _paths.entry(v);
    final res = await _client.send('GET', path, query: query);
    return ((res as Map)['snapshot'] as Map?)?.cast<String, dynamic>();
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _setProduction(Map<String, dynamic> e) async {
    if (!await _confirm(
      'Set as Production?',
      'This version is used from now on. The current one stays in the '
          'history.',
      'Set as Production',
    )) {
      return;
    }
    setState(() => _busy = true);
    try {
      final (path, query) = _paths.production();
      await _client.send(
        'POST',
        path,
        query: query,
        body: {
          'version_id': e['id'],
          if (widget.kind == 'skill') 'expected_version_id': _current,
        },
      );
      _changed = true;
      if (mounted) _say('In use now');
      await _load();
    } catch (err) {
      if (mounted) _say('$err');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete(Map<String, dynamic> e) async {
    if (!await _confirm(
      'Delete this version?',
      'It is removed from the history. This can\'t be undone.',
      'Delete',
    )) {
      return;
    }
    setState(() => _busy = true);
    try {
      final (path, query) = _paths.entry('${e['id']}');
      await _client.send('DELETE', path, query: query);
      await _load();
    } catch (err) {
      if (mounted) _say('$err');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _open(Map<String, dynamic> e) async {
    final id = '${e['id']}';
    final production = id == _current;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _VersionView(
          title: _when(e),
          load: () => _snapshot(id),
          loadCurrent: production || _current == null
              ? null
              : () => _snapshot(_current!),
          onProduction: production ? null : () => _setProduction(e),
        ),
      ),
    );
  }

  String _when(Map e) {
    final t = DateTime.fromMillisecondsSinceEpoch(
      ((e['created_at'] as num?) ?? 0).toInt() * 1000,
    );
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final muted = context.nexus.muted;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text('${widget.name} history')),
        body: list == null
            ? Center(
                child: _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('Couldn\'t load the history.\n$_error'),
                      )
                    : const CircularProgressIndicator(),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  children: [
                    if (_busy) const LinearProgressIndicator(minHeight: 2),
                    if (list.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No saved versions yet.',
                          style: TextStyle(color: muted),
                        ),
                      ),
                    for (final e in list)
                      ListTile(
                        leading: Icon(
                          e['id'] == _current
                              ? Icons.radio_button_checked
                              : Icons.history,
                          color: e['id'] == _current
                              ? NexusColors.accent
                              : muted,
                        ),
                        title: Text(
                          '${e['commit_message'] ?? ''}'.trim().isEmpty
                              ? _when(e)
                              : '${e['commit_message']}',
                        ),
                        subtitle: Text(
                          [
                            if ('${e['commit_message'] ?? ''}'
                                .trim()
                                .isNotEmpty)
                              _when(e),
                            if ((e['user'] as Map?)?['name'] != null)
                              '${(e['user'] as Map)['name']}',
                            if (e['id'] == _current) 'Production',
                          ].join(' · '),
                          style: TextStyle(color: muted),
                        ),
                        onTap: () => _open(e),
                        trailing: PopupMenuButton<String>(
                          enabled: !_busy,
                          onSelected: (v) =>
                              v == 'prod' ? _setProduction(e) : _delete(e),
                          itemBuilder: (_) => [
                            if (e['id'] != _current) ...[
                              const PopupMenuItem(
                                value: 'prod',
                                child: Text('Set as Production'),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete version'),
                              ),
                            ] else
                              const PopupMenuItem(
                                enabled: false,
                                value: '',
                                child: Text('In use now'),
                              ),
                          ],
                        ),
                      ),
                    if (_more && list.length >= 20)
                      TextButton(
                        onPressed: () {
                          _page++;
                          _load(next: true);
                        },
                        child: const Text('Load more'),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// One version's content, with a comparison to the one in use.
class _VersionView extends StatefulWidget {
  const _VersionView({
    required this.title,
    required this.load,
    this.loadCurrent,
    this.onProduction,
  });
  final String title;
  final Future<Map<String, dynamic>?> Function() load;
  final Future<Map<String, dynamic>?> Function()? loadCurrent;
  final Future<void> Function()? onProduction;

  @override
  State<_VersionView> createState() => _VersionViewState();
}

class _VersionViewState extends State<_VersionView> {
  String? _text;
  Object? _error;

  @override
  void initState() {
    super.initState();
    widget
        .load()
        .then((s) {
          if (mounted) setState(() => _text = snapshotText(s));
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e);
        });
  }

  Future<void> _compare() async {
    final now = snapshotText(await widget.loadCurrent!());
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => CompareTextScreen(original: now, revision: _text ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      actions: [
        if (_text != null) ...[
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy),
            onPressed: () => Clipboard.setData(ClipboardData(text: _text!)),
          ),
          if (widget.loadCurrent != null)
            IconButton(
              tooltip: 'Compare to current',
              icon: const Icon(Icons.difference_outlined),
              onPressed: _compare,
            ),
        ],
        if (widget.onProduction != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: () async {
                await widget.onProduction!();
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Set as Production'),
            ),
          ),
      ],
    ),
    body: _error != null
        ? Center(child: Text('$_error'))
        : _text == null
        ? const Center(child: CircularProgressIndicator())
        : SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              _text!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
  );
}
