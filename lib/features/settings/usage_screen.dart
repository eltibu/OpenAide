/// Settings > Usage, as on the web: how much you've used Nexus, your
/// streaks, weekly activity, and the models and tools you use most.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../server/community_share.dart' show communitySharingOn;
import 'usage_sync.dart';
import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import '../../core/i18n/app_strings.dart';

final usageProvider = FutureProvider.autoDispose<Map<String, dynamic>>((
  ref,
) async {
  final res = await ref
      .watch(clientProvider)
      .send('GET', '/api/v1/users/usage');
  return (res as Map).cast<String, dynamic>();
});

/// 1234567 as "1.2M", as the web shows big counts.
String shortNumber(num? n) {
  final v = (n ?? 0).toDouble();
  String one(double x) =>
      x >= 100 ? x.toStringAsFixed(0) : x.toStringAsFixed(1);
  if (v >= 1e9) return '${one(v / 1e9)}B';
  if (v >= 1e6) return '${one(v / 1e6)}M';
  if (v >= 1e3) return '${one(v / 1e3)}K';
  return v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
}

/// Seconds as "2h 5m", "4m", "30s".
String shortDuration(num? seconds) {
  final s = (seconds ?? 0).round();
  if (s >= 86400) return '${s ~/ 86400}d ${(s % 86400) ~/ 3600}h';
  if (s >= 3600) return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
  if (s >= 60) return '${s ~/ 60}m';
  return '${s}s';
}

class UsageScreen extends ConsumerStatefulWidget {
  const UsageScreen({super.key});

  @override
  ConsumerState<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends ConsumerState<UsageScreen> {
  String _measure = 'messages';

  @override
  Widget build(BuildContext context) {
    final usage = ref.watch(usageProvider);
    final models = ref.watch(modelsProvider).value ?? const [];
    final muted = context.nexus.muted;
    // Section names in the accent colour, as on every settings page.
    final heading = Theme.of(context).textTheme.titleSmall
        ?.copyWith(color: Theme.of(context).colorScheme.primary);
    String modelName(String id) =>
        models.where((m) => m.id == id).firstOrNull?.name ?? id;

    return Scaffold(
      appBar: AppBar(
        title: const T('Usage'),
        actions: [
          // As the web, when the server has community sharing on.
          if (communitySharingOn(ref.watch(serverConfigProvider).value))
            IconButton(
              tooltip: tr('Sync Usage Stats'),
              icon: const Icon(Icons.cloud_sync_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const UsageSyncScreen(),
                ),
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(usageProvider.future),
        child: usage.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load your usage.\n$e'),
              ),
            ],
          ),
          data: (u) {
            final totals = (u['totals'] as Map?) ?? const {};
            final insights = (u['insights'] as Map?) ?? const {};
            final topModels = (u['top_models'] as List? ?? const [])
                .whereType<Map>()
                .toList();
            final topTools = (u['top_tools'] as List? ?? const [])
                .whereType<Map>()
                .toList();
            final weeks = (u['weekly_heatmap'] as List? ?? const [])
                .whereType<Map>()
                .toList();
            final recent = weeks.length > 26
                ? weeks.sublist(weeks.length - 26)
                : weeks;
            Widget row(String label, String value) => ListTile(
              dense: true,
              title: Text(label),
              trailing: Text(value, style: TextStyle(color: muted)),
            );
            return ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _Tile(
                        'Lifetime tokens',
                        shortNumber(totals['lifetime_tokens'] as num?),
                      ),
                      _Tile(
                        'Peak tokens',
                        shortNumber(totals['peak_daily_tokens'] as num?),
                      ),
                      _Tile(
                        'Longest chat',
                        shortDuration(totals['longest_chat_seconds'] as num?),
                      ),
                      _Tile(
                        'Current streak',
                        '${totals['current_streak'] ?? 0} days',
                      ),
                      _Tile(
                        'Longest streak',
                        '${totals['longest_streak'] ?? 0} days',
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Row(
                    children: [
                      Expanded(child: T('Weekly activity', style: heading)),
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                        segments: const [
                          ButtonSegment(
                            value: 'messages',
                            label: T('Messages'),
                          ),
                          ButtonSegment(value: 'tokens', label: T('Tokens')),
                        ],
                        selected: {_measure},
                        onSelectionChanged: (s) =>
                            setState(() => _measure = s.first),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: SizedBox(
                    height: 120,
                    child: _Bars(
                      values: [
                        for (final w in recent)
                          ((w[_measure] as num?) ?? 0).toDouble(),
                      ],
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                if (recent.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Row(
                      children: [
                        Text(
                          '${recent.first['date']}',
                          style: TextStyle(color: muted, fontSize: 11),
                        ),
                        const Spacer(),
                        T(
                          'This week',
                          style: TextStyle(color: muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: T('Activity', style: heading),
                ),
                row('Models used', '${totals['models_used'] ?? 0}'),
                row(
                  'Average tokens per chat',
                  shortNumber(insights['average_tokens_per_chat'] as num?),
                ),
                row(
                  'Average messages per active day',
                  shortNumber(
                    insights['average_messages_per_active_day'] as num?,
                  ),
                ),
                row(
                  'Your messages',
                  '${totals['user_messages'] ?? 0} · '
                      '${shortNumber(insights['user_message_share'] as num?)}%',
                ),
                row(
                  'Replies',
                  '${totals['assistant_messages'] ?? 0} · '
                      '${shortNumber(insights['assistant_message_share'] as num?)}%',
                ),
                row('Chats', '${totals['total_chats'] ?? 0}'),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: T('Top models', style: heading),
                ),
                if (topModels.isEmpty)
                  ListTile(
                    title: T(
                      'No model usage yet',
                      style: TextStyle(color: muted),
                    ),
                  ),
                for (final m in topModels)
                  row(
                    modelName('${m['model_id']}'),
                    '${m['messages'] ?? 0} messages · '
                    '${shortNumber(m['total_tokens'] as num?)} tokens',
                  ),
                if (topTools.isNotEmpty) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: T('Most used tools', style: heading),
                  ),
                  for (final t in topTools)
                    row('${t['name']}', '${t['count'] ?? 0} runs'),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: T(
                    'Token counts are estimates and may not match what a '
                    'provider bills.',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 150,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: context.nexus.muted, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.titleLarge),
        ],
      ),
    );
  }
}

class _Bars extends StatelessWidget {
  const _Bars({required this.values, required this.color});
  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const SizedBox.shrink();
    final top = values.fold<double>(0, (a, b) => b > a ? b : a);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final v in values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: FractionallySizedBox(
                heightFactor: top == 0 ? 0.02 : (v / top).clamp(0.02, 1.0),
                alignment: Alignment.bottomCenter,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: v == 0 ? color.withValues(alpha: 0.15) : color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
