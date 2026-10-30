/// Admin > Analytics: messages, chats, people and tokens over a period, by
/// model and by person, with daily activity, and the Sessions explorer.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../../core/i18n/app_strings.dart';
import 'analytics_sessions.dart';

/// Periods offered, in days; null is all time.
const analyticsPeriods = <String, int?>{
  '24 hours': 1,
  '7 days': 7,
  '30 days': 30,
  '90 days': 90,
  'All time': null,
};

String _n(num v) => v >= 1e6
    ? '${(v / 1e6).toStringAsFixed(1)}M'
    : v >= 1e4
    ? '${(v / 1e3).toStringAsFixed(1)}k'
    : '$v';

class AnalyticsScreen extends ConsumerStatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  ConsumerState<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends ConsumerState<AnalyticsScreen> {
  String _period = '30 days';
  DateTimeRange? _custom;
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _models = [];
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _daily = [];
  Map<String, Map<String, dynamic>> _tokens = {};
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, String> get _range {
    int secs(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
    if (_custom case final r?) {
      return {
        'start_date': '${secs(r.start)}',
        'end_date': '${secs(r.end.add(const Duration(days: 1)))}',
      };
    }
    final days = analyticsPeriods[_period];
    if (days == null) return {};
    final now = DateTime.now();
    return {
      'start_date': '${secs(now.subtract(Duration(days: days)))}',
      'end_date': '${secs(now)}',
    };
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final client = ref.read(clientProvider);
    final q = _range;
    List<Map<String, dynamic>> rows(Object? v) => [
      for (final r in v as List? ?? const [])
        if (r is Map) r.cast<String, dynamic>(),
    ];
    try {
      final days = analyticsPeriods[_period];
      final results = await Future.wait([
        client.send('GET', '/api/v1/analytics/summary', query: q),
        client.send('GET', '/api/v1/analytics/models', query: q),
        client.send('GET', '/api/v1/analytics/users', query: q),
        client.send(
          'GET',
          '/api/v1/analytics/daily',
          query: {
            ...q,
            if (days == 1 && _custom == null) 'granularity': 'hourly',
          },
        ),
        client.send('GET', '/api/v1/analytics/tokens', query: q),
      ]);
      _summary = (results[0] as Map).cast<String, dynamic>();
      _models = rows((results[1] as Map)['models']);
      _users = rows((results[2] as Map)['users']);
      _daily = rows((results[3] as Map)['data']);
      _tokens = {
        for (final t in rows((results[4] as Map)['models']))
          '${t['model_id']}': t,
      };
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2023),
      lastDate: now,
      initialDateRange: _custom,
    );
    if (r == null) return;
    _custom = r;
    _load();
  }

  Widget _stat(String label, Object? value) => Expanded(
    child: Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Column(
          children: [
            Text(
              value is num ? _n(value) : '${value ?? '–'}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(label, style: TextStyle(color: context.nexus.muted)),
          ],
        ),
      ),
    ),
  );

  Widget _activity() {
    final totals = [
      for (final d in _daily)
        ((d['models'] as Map?) ?? const {}).values.fold<num>(
          0,
          (a, b) => a + (b is num ? b : 0),
        ),
    ];
    if (totals.isEmpty) return const SizedBox.shrink();
    final top = math.max(1, totals.reduce(math.max));
    final muted = context.nexus.muted;
    String label(Map d) {
      final s = '${d['date'] ?? ''}';
      return s.length > 5 ? s.substring(5) : s;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          T('Activity', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 120,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (i, t) in totals.indexed)
                  Expanded(
                    child: Tooltip(
                      message: '${_daily[i]['date']}: $t messages',
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        height: math.max(2, 120 * t / top),
                        decoration: BoxDecoration(
                          color: NexusColors.accent,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label(_daily.first),
                style: TextStyle(color: muted, fontSize: 12),
              ),
              Text(
                label(_daily.last),
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final s = _summary;
    return Scaffold(
      appBar: AppBar(
        title: const T('Analytics'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.forum_outlined),
            label: const T('Sessions'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AnalyticsSessionsScreen(range: _range),
              ),
            ),
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
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  for (final p in analyticsPeriods.keys)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(p),
                        selected: _custom == null && _period == p,
                        onSelected: (_) {
                          _custom = null;
                          _period = p;
                          _load();
                        },
                      ),
                    ),
                  ChoiceChip(
                    avatar: const Icon(Icons.date_range, size: 16),
                    label: Text(
                      _custom == null
                          ? 'Dates'
                          : '${MaterialLocalizations.of(context).formatShortDate(_custom!.start)} – '
                                '${MaterialLocalizations.of(context).formatShortDate(_custom!.end)}',
                    ),
                    selected: _custom != null,
                    onSelected: (_) => _pickRange(),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load analytics.\n$_error'),
              ),
            if (s != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    _stat('Messages', s['total_messages']),
                    _stat('Chats', s['total_chats']),
                    _stat('Models', s['total_models']),
                    _stat('People', s['total_users']),
                  ],
                ),
              ),
              _activity(),
              _heading('Models'),
              if (_models.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: T(
                    'Nothing in this period.',
                    style: TextStyle(color: muted),
                  ),
                ),
              for (final m in _models)
                ListTile(
                  dense: true,
                  title: Text('${m['model_id']}'),
                  subtitle: Text(
                    '${m['unique_users'] ?? 0} people · ${m['unique_chats'] ?? 0} chats'
                    ' · ${_n((_tokens['${m['model_id']}']?['total_tokens'] as num?) ?? 0)} tokens',
                    style: TextStyle(color: muted),
                  ),
                  trailing: Text(_n((m['count'] as num?) ?? 0)),
                ),
              _heading('People'),
              for (final u in _users)
                ListTile(
                  dense: true,
                  title: Text('${u['name'] ?? u['email'] ?? u['user_id']}'),
                  subtitle: Text(
                    '${u['email'] ?? ''} · ${_n((u['total_tokens'] as num?) ?? 0)} tokens',
                    style: TextStyle(color: muted),
                  ),
                  trailing: Text(_n((u['count'] as num?) ?? 0)),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
