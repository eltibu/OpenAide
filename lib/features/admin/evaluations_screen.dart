/// Admin > Evaluations: the model leaderboard built from people's ratings,
/// and the ratings themselves.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';

const _base = '/api/v1/evaluations';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

class EvaluationsScreen extends StatelessWidget {
  const EvaluationsScreen({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Evaluations'),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Leaderboard'),
            Tab(text: 'Feedback'),
          ],
        ),
      ),
      body: const TabBarView(children: [LeaderboardView(), FeedbackView()]),
    ),
  );
}

class LeaderboardView extends ConsumerStatefulWidget {
  const LeaderboardView({super.key});

  @override
  ConsumerState<LeaderboardView> createState() => _LeaderboardViewState();
}

class _LeaderboardViewState extends ConsumerState<LeaderboardView> {
  List<Map<String, dynamic>>? _entries;
  Object? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res =
          await ref
                  .read(clientProvider)
                  .send(
                    'GET',
                    '$_base/leaderboard',
                    query: _query.isEmpty ? null : {'query': _query},
                  )
              as Map;
      _entries = [
        for (final e in res['entries'] as List? ?? const [])
          if (e is Map) e.cast<String, dynamic>(),
      ];
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final entries = _entries;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Rank by topic (matches feedback tags)',
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (v) {
                _query = v.trim();
                _load();
              },
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Couldn\'t load the leaderboard.\n$_error'),
            )
          else if (entries == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No ratings yet. Thumbs up or down on replies (or arena '
                'comparisons) rank the models here.',
                style: TextStyle(color: muted),
              ),
            ),
          for (final (i, e)
              in (entries ?? const <Map<String, dynamic>>[]).indexed)
            ListTile(
              leading: CircleAvatar(child: Text('${i + 1}')),
              title: Text('${e['model_id']}'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Won ${e['won'] ?? 0} · lost ${e['lost'] ?? 0} · '
                    '${e['count'] ?? 0} ratings',
                    style: TextStyle(color: muted),
                  ),
                  if ((e['top_tags'] as List? ?? const []).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final t
                              in (e['top_tags'] as List).whereType<Map>())
                            Chip(
                              visualDensity: VisualDensity.compact,
                              label: Text('${t['tag']} ${t['count'] ?? ''}'),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
              trailing: Text(
                '${e['rating']}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
        ],
      ),
    );
  }
}

class FeedbackView extends ConsumerStatefulWidget {
  const FeedbackView({super.key});

  @override
  ConsumerState<FeedbackView> createState() => _FeedbackViewState();
}

class _FeedbackViewState extends ConsumerState<FeedbackView> {
  final List<Map<String, dynamic>> _items = [];
  int _total = 0;
  int _page = 0;
  bool _loading = false;
  Object? _error;
  String? _model;
  List<String> _models = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    _items.clear();
    _page = 0;
    try {
      _models = [
        for (final m
            in await ref
                        .read(clientProvider)
                        .send('GET', '$_base/feedbacks/models')
                    as List? ??
                const [])
          '$m',
      ];
    } catch (_) {}
    await _more();
  }

  Future<void> _more() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final res =
          await ref
                  .read(clientProvider)
                  .send(
                    'GET',
                    '$_base/feedbacks/list',
                    query: {'page': '${_page + 1}', 'model_id': ?_model},
                  )
              as Map;
      _page++;
      _total = (res['total'] as num?)?.toInt() ?? 0;
      _items.addAll([
        for (final f in res['items'] as List? ?? const [])
          if (f is Map) f.cast<String, dynamic>(),
      ]);
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<bool> _confirm(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
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
      ) ==
      true;

  Future<void> _delete(Map<String, dynamic> f) async {
    if (!await _confirm('Delete this feedback?')) return;
    try {
      await ref
          .read(clientProvider)
          .send('DELETE', '$_base/feedback/${f['id']}');
      setState(() {
        _items.remove(f);
        _total--;
      });
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  Future<void> _deleteAll() async {
    if (!await _confirm('Delete all feedback?')) return;
    try {
      await ref.read(clientProvider).send('DELETE', '$_base/feedbacks/all');
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    await _reload();
  }

  Future<void> _export() async {
    try {
      final data = await ref
          .read(clientProvider)
          .send('GET', '$_base/feedbacks/all/export');
      final name =
          'feedback-history-export-${DateTime.now().millisecondsSinceEpoch}.json';
      final saved = await FilePicker.saveFile(
        fileName: name,
        bytes: Uint8List.fromList(utf8.encode(jsonEncode(data))),
      );
      if (saved != null && mounted) _say(context, 'Saved $name');
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final loc = MaterialLocalizations.of(context);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 300 && _items.length < _total) _more();
        return false;
      },
      child: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      initialValue: _model,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Model'),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('All models'),
                        ),
                        for (final m in _models)
                          DropdownMenuItem(
                            value: m,
                            child: Text(m, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (v) {
                        _model = v;
                        _reload();
                      },
                    ),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) => v == 'export' ? _export() : _deleteAll(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'export', child: Text('Export all')),
                      PopupMenuItem(value: 'delete', child: Text('Delete all')),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('$_total ratings', style: TextStyle(color: muted)),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load feedback.\n$_error'),
              ),
            for (final f in _items)
              () {
                final data = (f['data'] as Map?) ?? const {};
                final rating = data['rating'];
                final up = rating == 1 || rating == '1';
                final user = (f['user'] as Map?) ?? const {};
                final when = DateTime.fromMillisecondsSinceEpoch(
                  ((f['updated_at'] as num?)?.toInt() ?? 0) * 1000,
                );
                final note = [
                  if ('${data['reason'] ?? ''}'.isNotEmpty) data['reason'],
                  if ('${data['comment'] ?? ''}'.isNotEmpty) data['comment'],
                ].join(' · ');
                return ListTile(
                  leading: Icon(
                    up ? Icons.thumb_up_outlined : Icons.thumb_down_outlined,
                    color: up ? Colors.green : NexusColors.accent,
                  ),
                  title: Text('${data['model_id'] ?? ''}'),
                  subtitle: Text(
                    [
                      if (note.isNotEmpty) note,
                      '${user['name'] ?? ''} · ${loc.formatShortDate(when)}',
                    ].join('\n'),
                    style: TextStyle(color: muted),
                  ),
                  trailing: IconButton(
                    tooltip: 'Delete',
                    onPressed: () => _delete(f),
                    icon: const Icon(Icons.delete_outline),
                  ),
                );
              }(),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}
