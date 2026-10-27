import '../../core/api/openwebui_client.dart';
import '../notes/notes_api.dart' show fromServerTime;

/// A prompt the server runs on a schedule, into a new chat or a channel.
class Automation {
  const Automation({
    required this.id,
    required this.name,
    required this.data,
    required this.active,
    this.folderId,
    this.nextRun,
    this.lastRun,
    this.lastStatus,
  });

  factory Automation.fromJson(Map j) {
    final last = j['last_run'] as Map?;
    return Automation(
      id: '${j['id']}',
      name: '${j['name'] ?? ''}',
      data: (j['data'] as Map?)?.cast<String, dynamic>() ?? const {},
      active: j['is_active'] == true,
      folderId: j['folder_id'] as String?,
      nextRun: j['next_run_at'] is num
          ? fromServerTime(j['next_run_at'] as num)
          : null,
      lastRun: j['last_run_at'] is num
          ? fromServerTime(j['last_run_at'] as num)
          : null,
      lastStatus: last?['status'] as String?,
    );
  }

  final String id;
  final String name;

  /// prompt, model_id, rrule, target, terminal: as the server keeps them.
  final Map<String, dynamic> data;
  final bool active;
  final String? folderId;
  final DateTime? nextRun;
  final DateTime? lastRun;
  final String? lastStatus;

  String get prompt => '${data['prompt'] ?? ''}';
  String get modelId => '${data['model_id'] ?? ''}';
  String get rrule => '${data['rrule'] ?? ''}';
  String? get channelId => (data['target'] as Map?)?['type'] == 'channel'
      ? (data['target'] as Map)['channel_id'] as String?
      : null;
}

class AutomationRun {
  const AutomationRun({
    required this.id,
    required this.status,
    required this.at,
    this.chatId,
    this.error,
  });

  factory AutomationRun.fromJson(Map j) => AutomationRun(
    id: '${j['id']}',
    status: '${j['status'] ?? ''}',
    at: fromServerTime((j['created_at'] as num?) ?? 0),
    chatId: j['chat_id'] as String?,
    error: j['error'] as String?,
  );

  final String id;
  final String status;
  final DateTime at;
  final String? chatId;
  final String? error;
}

class AutomationsApi {
  AutomationsApi(this.client);
  final OpenWebUiClient client;

  static const _base = '/api/v1/automations';
  String _id(String id) => '$_base/${Uri.encodeComponent(id)}';

  Future<List<Automation>> list() async {
    final out = <Automation>[];
    for (var page = 1; page < 20; page++) {
      final res = await client.send(
        'GET',
        '$_base/list',
        query: {'page': '$page'},
      ) as Map;
      final items = (res['items'] as List? ?? const []).whereType<Map>();
      out.addAll(items.map(Automation.fromJson));
      if (items.isEmpty || out.length >= ((res['total'] as num?) ?? 0)) break;
    }
    return out;
  }

  Future<Automation> get(String id) async =>
      Automation.fromJson(await client.send('GET', _id(id)) as Map);

  Future<List<AutomationRun>> runs(String id) async {
    final res = await client.send(
      'GET',
      '${_id(id)}/runs',
      query: {'skip': '0', 'limit': '50'},
    );
    return [
      for (final r in (res as List? ?? const []).whereType<Map>())
        AutomationRun.fromJson(r),
    ];
  }

  Future<Automation> save(String? id, Map<String, dynamic> form) async =>
      Automation.fromJson(
        await client.send(
          'POST',
          id == null ? '$_base/create' : '${_id(id)}/update',
          body: form,
        ) as Map,
      );

  Future<void> toggle(String id) => client.send('POST', '${_id(id)}/toggle');
  Future<void> run(String id) => client.send('POST', '${_id(id)}/run');
  Future<void> delete(String id) => client.send('DELETE', '${_id(id)}/delete');
}

/// The web UI's schedule choices, read from and written to an RRULE.
class Schedule {
  Schedule({
    this.frequency = 'DAILY',
    this.interval = 1,
    this.hour = 9,
    this.minute = 0,
    List<String>? days,
    this.monthDay = 1,
    DateTime? once,
    this.custom = '',
  }) : days = days ?? [],
       once = once ?? DateTime.now().add(const Duration(minutes: 5));

  /// ONCE, HOURLY, DAILY, WEEKLY, MONTHLY or CUSTOM.
  String frequency;
  int interval;
  int hour;
  int minute;
  List<String> days;
  int monthDay;
  DateTime once;
  String custom;

  static const weekDays = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

  static String _two(int v) => '$v'.padLeft(2, '0');

  factory Schedule.parse(String s) {
    final start = RegExp(
      r'DTSTART[^:]*:(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})',
      caseSensitive: false,
    ).firstMatch(s);
    if (RegExp(r'COUNT=1(?!\d)').hasMatch(s)) {
      return Schedule(
        frequency: 'ONCE',
        once: start == null
            ? null
            : DateTime(
                int.parse(start[1]!),
                int.parse(start[2]!),
                int.parse(start[3]!),
                int.parse(start[4]!),
                int.parse(start[5]!),
              ),
      );
    }
    final parts = <String, String>{};
    for (final p
        in s
            .split(RegExp(r'\s+'))
            .where((l) => !l.toUpperCase().startsWith('DTSTART'))
            .join()
            .replaceFirst('RRULE:', '')
            .split(';')) {
      final kv = p.split('=');
      if (kv.length == 2 && kv[0].isNotEmpty) parts[kv[0]] = kv[1];
    }
    final freq = parts['FREQ'] ?? 'DAILY';
    if (!['HOURLY', 'DAILY', 'WEEKLY', 'MONTHLY'].contains(freq) ||
        parts.containsKey('COUNT') ||
        parts.containsKey('UNTIL')) {
      return Schedule(frequency: 'CUSTOM', custom: s);
    }
    return Schedule(
      frequency: freq,
      interval: int.tryParse(parts['INTERVAL'] ?? '') ?? 1,
      hour: int.tryParse(parts['BYHOUR'] ?? start?[4] ?? '') ?? 9,
      minute: int.tryParse(parts['BYMINUTE'] ?? start?[5] ?? '') ?? 0,
      days: parts['BYDAY']?.split(',') ?? [],
      monthDay: int.tryParse(parts['BYMONTHDAY'] ?? '') ?? 1,
    );
  }

  String build() {
    if (frequency == 'CUSTOM') return custom;
    if (frequency == 'ONCE') {
      final o = once;
      return 'DTSTART:${o.year}${_two(o.month)}${_two(o.day)}'
          'T${_two(o.hour)}${_two(o.minute)}00\nRRULE:FREQ=DAILY;COUNT=1';
    }
    final parts = ['FREQ=$frequency'];
    if (interval > 1) parts.add('INTERVAL=$interval');
    if (frequency == 'WEEKLY' && days.isNotEmpty) {
      parts.add('BYDAY=${days.join(',')}');
    }
    if (frequency == 'MONTHLY') parts.add('BYMONTHDAY=$monthDay');
    if (['DAILY', 'WEEKLY', 'MONTHLY'].contains(frequency)) {
      parts.add('BYHOUR=$hour');
    }
    parts.add('BYMINUTE=$minute');
    return 'RRULE:${parts.join(';')}';
  }

  /// In words, as the web shows it.
  String describe(String Function(int hour, int minute) time) {
    final at = time(hour, minute);
    return switch (frequency) {
      'ONCE' =>
        'Once · ${once.month}/${once.day} ${time(once.hour, once.minute)}',
      'HOURLY' => interval == 1 ? 'Hourly' : 'Every $interval hours',
      'DAILY' => 'Daily at $at',
      'WEEKLY' =>
        days.isEmpty
            ? 'Weekly at $at'
            : '${days.map((d) => d[0] + d.substring(1).toLowerCase()).join(', ')} at $at',
      'MONTHLY' => 'Monthly on day $monthDay at $at',
      _ => custom,
    };
  }
}
