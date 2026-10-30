/// Admin > Analytics > Sessions: each chat in the period with its tokens,
/// replies, errors and time span; open one for its saved replies and the
/// tool calls each made, with timing and outcome. The server only answers
/// while "ENABLE_ADMIN_CHAT_ACCESS" is on, as on the web.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart' show ApiException;
import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart' show modelsProvider;

const _base = '/api/v1/analytics/sessions';

/// The web's token buckets, matching the server's TOKEN_RANGES.
const sessionTokenRanges = <(String, int, int?)>[
  ('No tokens', 0, 1),
  ('Under 1k', 1, 1000),
  ('1k–10k', 1000, 10000),
  ('10k–100k', 10000, 100000),
  ('100k–1M', 100000, 1000000),
  ('Over 1M', 1000000, null),
];

const _orders = <String, String>{
  'recent': 'Recent',
  'tokens': 'Tokens',
  'responses': 'Responses',
  'errors': 'Errors',
  'duration': 'Duration',
  'title': 'Title',
  'user': 'User',
};

String _n(num v) => v >= 1e6
    ? '${(v / 1e6).toStringAsFixed(1)}M'
    : v >= 1e4
    ? '${(v / 1e3).toStringAsFixed(1)}k'
    : '$v';

/// "3m 12s" for a span in seconds.
String sessionSpan(num? seconds) {
  if (seconds == null) return '–';
  final s = seconds.round();
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
  if (s < 86400) return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
  return '${s ~/ 86400}d ${(s % 86400) ~/ 3600}h';
}

String _when(Object? secs) {
  if (secs is! num) return '';
  final d = DateTime.fromMillisecondsSinceEpoch((secs * 1000).round());
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}

String _sessionError(Object e) => e is ApiException && e.statusCode == 403
    ? tr(
        'Sessions need admin chat access (ENABLE_ADMIN_CHAT_ACCESS) on the server.',
      )
    : '$e';

class AnalyticsSessionsScreen extends ConsumerStatefulWidget {
  const AnalyticsSessionsScreen({super.key, this.range = const {}});

  /// start_date / end_date in seconds, from the Analytics period.
  final Map<String, String> range;

  @override
  ConsumerState<AnalyticsSessionsScreen> createState() =>
      _AnalyticsSessionsScreenState();
}

class _AnalyticsSessionsScreenState
    extends ConsumerState<AnalyticsSessionsScreen> {
  final _search = TextEditingController();
  final _items = <Map<String, dynamic>>[];
  Map<String, dynamic>? _overview;
  String? _model;
  int? _tokenRange;
  bool _hideSubagents = false;
  String _order = 'recent';
  bool _asc = false;
  bool _more = false;
  bool _loading = false;
  Object? _error;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final gen = ++_gen;
    setState(() => _loading = true);
    final range = _tokenRange == null ? null : sessionTokenRanges[_tokenRange!];
    try {
      final res = await ref
          .read(clientProvider)
          .send(
            'GET',
            _base,
            query: {
              ...widget.range,
              'query': _search.text.trim(),
              'model_id': ?_model,
              if (_hideSubagents) 'hide_subagents': 'true',
              'order_by': _order,
              'direction': _asc ? 'asc' : 'desc',
              if (!more) 'include_summary': 'true',
              if (range != null) 'token_min': '${range.$2}',
              if (range?.$3 case final max?) 'token_max': '$max',
              'skip': '${more ? _items.length : 0}',
              'limit': '25',
            },
          );
      if (gen != _gen || !mounted) return;
      final m = (res as Map).cast<String, dynamic>();
      setState(() {
        if (!more) _items.clear();
        _items.addAll([
          for (final r in m['items'] as List? ?? const [])
            if (r is Map) r.cast<String, dynamic>(),
        ]);
        if (m['overview'] case final Map o) {
          _overview = o.cast<String, dynamic>();
        }
        _more = m['has_more'] == true;
        _error = null;
      });
    } catch (e) {
      if (gen == _gen && mounted) setState(() => _error = e);
    }
    if (gen == _gen && mounted) setState(() => _loading = false);
  }

  Widget _stat(String label, Object? value) => Expanded(
    child: Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: Column(
          children: [
            Text(
              value is num ? _n(value) : '${value ?? '–'}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            T(label, style: TextStyle(color: context.nexus.muted)),
          ],
        ),
      ),
    ),
  );

  Future<void> _filters() async {
    final models = ref.read(modelsProvider).value ?? const [];
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (s) => StatefulBuilder(
        builder: (s, redraw) {
          void set(VoidCallback f) {
            f();
            redraw(() {});
            _load();
          }

          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                T('Sort by', style: Theme.of(s).textTheme.titleSmall),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final e in _orders.entries)
                      ChoiceChip(
                        label: T(e.value),
                        selected: _order == e.key,
                        onSelected: (_) => set(() => _order = e.key),
                      ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const T('Oldest / smallest first'),
                  value: _asc,
                  onChanged: (v) => set(() => _asc = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const T('Hide sub-agents'),
                  value: _hideSubagents,
                  onChanged: (v) => set(() => _hideSubagents = v),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  initialValue: _model,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: tr('Model')),
                  items: [
                    DropdownMenuItem(value: null, child: T('All models')),
                    for (final m in models)
                      DropdownMenuItem(
                        value: m.id,
                        child: Text(m.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => set(() => _model = v),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _distribution() {
    final dist = _overview?['token_distribution'];
    if (dist is! List || dist.length != sessionTokenRanges.length) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          for (final (i, r) in sessionTokenRanges.indexed)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text('${tr(r.$1)} · ${dist[i]}'),
                selected: _tokenRange == i,
                onSelected: (on) {
                  _tokenRange = on ? i : null;
                  _load();
                },
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final o = _overview;
    return Scaffold(
      appBar: AppBar(
        title: const T('Sessions'),
        actions: [
          IconButton(
            tooltip: tr('Filters'),
            icon: const Icon(Icons.tune),
            onPressed: _filters,
          ),
        ],
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: tr('Search title, user or folder'),
                  isDense: true,
                ),
                onSubmitted: (_) => _load(),
              ),
            ),
            if (o != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    _stat('Sessions', o['sessions']),
                    _stat('Tokens', o['tokens']),
                    _stat('Responses', o['responses']),
                    _stat('Errors', o['errors']),
                  ],
                ),
              ),
            _distribution(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_sessionError(_error!)),
              ),
            if (_error == null && !_loading && _items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: T('No sessions found.', style: TextStyle(color: muted)),
              ),
            for (final s in _items)
              ListTile(
                title: Text(
                  '${s['title'] ?? ''}'.isEmpty
                      ? tr('Untitled')
                      : '${s['title']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    '${s['user_name'] ?? ''}',
                    if (s['model_id'] != null)
                      '${s['model_id']}'
                          '${(s['model_count'] as num? ?? 0) > 1 ? ' +${(s['model_count'] as num) - 1}' : ''}',
                    if (s['kind'] == 'subagent') tr('sub-agent'),
                    if (s['folder_name'] != null) '${s['folder_name']}',
                  ].where((e) => e.isNotEmpty).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted),
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      (s['recorded_responses'] as num? ?? 0) > 0
                          ? '${_n(s['tokens'] as num? ?? 0)} tok'
                          : '–',
                    ),
                    Text(
                      '${s['responses'] ?? 0} ${tr('replies')}'
                      '${(s['errors'] as num? ?? 0) > 0 ? ' · ${s['errors']} ⚠' : ''}'
                      ' · ${sessionSpan(s['span_seconds'] as num?)}',
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  ],
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SessionDetailScreen(
                      chatId: '${s['id']}',
                      title: '${s['title'] ?? ''}',
                      range: widget.range,
                    ),
                  ),
                ),
              ),
            if (_more)
              Padding(
                padding: const EdgeInsets.all(12),
                child: OutlinedButton(
                  onPressed: _loading ? null : () => _load(more: true),
                  child: const T('Load more'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One session: its saved messages in order, each reply's tool calls on tap.
class SessionDetailScreen extends ConsumerStatefulWidget {
  const SessionDetailScreen({
    super.key,
    required this.chatId,
    required this.title,
    this.range = const {},
  });

  final String chatId;
  final String title;
  final Map<String, String> range;

  @override
  ConsumerState<SessionDetailScreen> createState() =>
      _SessionDetailScreenState();
}

class _SessionDetailScreenState extends ConsumerState<SessionDetailScreen> {
  final _items = <Map<String, dynamic>>[];
  Map<String, dynamic>? _session;
  bool _more = false;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    setState(() => _loading = true);
    try {
      final res = await ref
          .read(clientProvider)
          .send(
            'GET',
            '$_base/${Uri.encodeComponent(widget.chatId)}',
            query: {
              ...widget.range,
              'skip': '${more ? _items.length : 0}',
              'limit': '25',
            },
          );
      final m = (res as Map).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        if (!more) _items.clear();
        _session = (m['session'] as Map?)?.cast<String, dynamic>();
        _items.addAll([
          for (final r in m['items'] as List? ?? const [])
            if (r is Map) r.cast<String, dynamic>(),
        ]);
        _more = m['has_more'] == true;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _events(Map<String, dynamic> msg) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scroll) => _EventsSheet(
          chatId: widget.chatId,
          messageId: '${msg['id']}',
          range: widget.range,
          scroll: scroll,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final s = _session;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isEmpty ? tr('Session') : widget.title),
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_sessionError(_error!)),
            ),
          if (s != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  Text('${tr('User')}: ${s['user_name'] ?? '–'}'),
                  Text('${tr('Tokens')}: ${_n(s['tokens'] as num? ?? 0)}'),
                  Text('${tr('Responses')}: ${s['responses'] ?? 0}'),
                  Text('${tr('Errors')}: ${s['errors'] ?? 0}'),
                  Text(
                    '${tr('Time span')}: ${sessionSpan(s['span_seconds'] as num?)}',
                  ),
                  Text(
                    '${_when(s['started_at'])} – ${_when(s['last_active'])}',
                    style: TextStyle(color: muted),
                  ),
                ],
              ),
            ),
          for (final m in _items)
            ListTile(
              leading: Icon(
                m['role'] == 'user'
                    ? Icons.person_outline
                    : m['error'] != null
                    ? Icons.error_outline
                    : Icons.smart_toy_outlined,
                color: m['error'] != null
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
              title: Text(
                '${m['error'] ?? m['preview'] ?? ''}'.trim().isEmpty
                    ? '(${tr('no text')})'
                    : '${m['error'] ?? m['preview']}',
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  _when(m['created_at']),
                  if (m['model_id'] != null) '${m['model_id']}',
                  if (m['tokens'] != null) '${_n(m['tokens'] as num)} tok',
                  if ((m['output_count'] as num? ?? 0) > 0)
                    '${m['output_count']} ${tr('steps')}',
                ].join(' · '),
                style: TextStyle(color: muted, fontSize: 12),
              ),
              onTap: m['role'] == 'assistant' ? () => _events(m) : null,
            ),
          if (_more)
            Padding(
              padding: const EdgeInsets.all(12),
              child: OutlinedButton(
                onPressed: _loading ? null : () => _load(more: true),
                child: const T('Load more'),
              ),
            ),
        ],
      ),
    );
  }
}

/// A reply's saved tool calls and steps, with their timing and outcome.
class _EventsSheet extends ConsumerStatefulWidget {
  const _EventsSheet({
    required this.chatId,
    required this.messageId,
    required this.range,
    required this.scroll,
  });

  final String chatId, messageId;
  final Map<String, String> range;
  final ScrollController scroll;

  @override
  ConsumerState<_EventsSheet> createState() => _EventsSheetState();
}

class _EventsSheetState extends ConsumerState<_EventsSheet> {
  final _items = <Map<String, dynamic>>[];
  bool _more = false;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    setState(() => _loading = true);
    try {
      final res = await ref
          .read(clientProvider)
          .send(
            'GET',
            '$_base/${Uri.encodeComponent(widget.chatId)}/messages/'
                '${Uri.encodeComponent(widget.messageId)}/events',
            query: {
              ...widget.range,
              'skip': '${more ? _items.length : 0}',
              'limit': '20',
            },
          );
      final m = (res as Map).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _items.addAll([
          for (final r in m['items'] as List? ?? const [])
            if (r is Map) r.cast<String, dynamic>(),
        ]);
        _more = m['has_more'] == true;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: T(
            'Tool calls and steps',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_sessionError(_error!)),
          ),
        if (!_loading && _error == null && _items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: T(
              'This reply made no tool calls.',
              style: TextStyle(color: muted),
            ),
          ),
        for (final e in _items)
          ExpansionTile(
            leading: Icon(switch ('${e['status']}') {
              'completed' => Icons.check_circle_outline,
              'failed' || 'incomplete' => Icons.error_outline,
              _ => Icons.timelapse,
            }),
            title: Text('${e['name'] ?? e['type'] ?? ''}'),
            subtitle: Text(
              [
                '${e['type'] ?? ''}',
                if (e['status'] != null) '${e['status']}',
                if (e['error_type'] != null) '${e['error_type']}',
                if (e['duration_seconds'] is num)
                  '${(e['duration_seconds'] as num).toStringAsFixed(1)}s',
              ].where((s) => s.isNotEmpty).join(' · '),
              style: TextStyle(color: muted, fontSize: 12),
            ),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              SelectableText(
                '${e['details'] ?? ''}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        if (_more)
          Padding(
            padding: const EdgeInsets.all(12),
            child: OutlinedButton(
              onPressed: _loading ? null : () => _load(more: true),
              child: const T('Load more'),
            ),
          ),
      ],
    );
  }
}
