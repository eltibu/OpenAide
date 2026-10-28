/// The tools and instructions a chat without a server gets: the built-in
/// tools (web, calculator, phone, calendar, memory, notes), skills, your
/// MCP servers and your tool servers.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_loop.dart';
import '../../core/agent/calculator.dart';
import '../../core/agent/skills.dart';
import '../../core/agent/web_tools.dart';
import '../phone/phone_actions.dart';
import '../settings/tool_servers.dart'
    show toolServerData, runToolServer, openApiTools;
import 'agent_store.dart';
import 'mcp_servers.dart';

/// A built-in tool as Tools and skills lists it.
class BuiltInTool {
  const BuiltInTool(this.name, this.label, this.description, this.group);
  final String name;
  final String label;
  final String description;
  final String group;
}

const builtInTools = [
  BuiltInTool('web_search', 'Web search', 'Search the web', 'Web'),
  BuiltInTool('fetch_page', 'Read web pages', 'Open a link and read it', 'Web'),
  BuiltInTool('calculator', 'Calculator', 'Exact maths', 'Basics'),
  BuiltInTool(
    'current_time',
    'Date and time',
    'Today, now, time zone',
    'Basics',
  ),
  BuiltInTool('set_timer', 'Timers', 'Start a timer', 'Phone'),
  BuiltInTool('set_alarm', 'Alarms', 'Set an alarm', 'Phone'),
  BuiltInTool('call_contact', 'Calls', 'Ready a call to a contact', 'Phone'),
  BuiltInTool('send_text', 'Texts', 'Ready a text message', 'Phone'),
  BuiltInTool('open_app', 'Open apps', 'Open an app on the phone', 'Phone'),
  BuiltInTool('directions', 'Directions', 'Open maps to a place', 'Phone'),
  BuiltInTool('flashlight', 'Flashlight', 'Turn the light on or off', 'Phone'),
  BuiltInTool(
    'add_calendar_event',
    'Calendar',
    'Add events (you confirm in your calendar)',
    'Phone',
  ),
  BuiltInTool('remember', 'Memory', 'Remember and forget facts', 'Memory'),
  BuiltInTool('save_note', 'Notes', 'Save, list and read notes', 'Memory'),
];

/// Tools that switch on and off with another one in the list.
const _toolGroups = {
  'forget': 'remember',
  'list_notes': 'save_note',
  'read_note': 'save_note',
};

/// What a chat runs with.
class AgentKit {
  const AgentKit(this.tools, this.instructions, this.problems);
  final List<AgentTool> tools;

  /// Goes after your own system prompt.
  final String instructions;

  /// Servers that didn't answer, by name.
  final Map<String, String> problems;
}

final mcpPoolProvider = Provider<McpPool>((ref) {
  final pool = McpPool(ref.read(agentStoreProvider.notifier));
  ref.onDispose(pool.closeAll);
  return pool;
});

/// [small] is for models on the phone: the built-ins small models handle
/// well, with your servers' tools only when you have few.
Future<AgentKit> buildAgentKit(
  Ref ref, {
  bool small = false,
  Future<Map?> Function(List<Map> people)? pickContact,
}) async {
  final store = ref.read(agentStoreProvider.notifier);
  final config = await ref.read(agentStoreProvider.future);
  return _build(
    config,
    store,
    ref.read(mcpPoolProvider),
    small: small,
    pickContact: pickContact,
  );
}

/// The same, from a widget.
Future<AgentKit> buildAgentKitFor(
  WidgetRef ref, {
  bool small = false,
  Future<Map?> Function(List<Map> people)? pickContact,
}) async {
  final store = ref.read(agentStoreProvider.notifier);
  final config = await ref.read(agentStoreProvider.future);
  return _build(
    config,
    store,
    ref.read(mcpPoolProvider),
    small: small,
    pickContact: pickContact,
  );
}

Future<AgentKit> _build(
  AgentConfig config,
  AgentStore store,
  McpPool pool, {
  required bool small,
  Future<Map?> Function(List<Map> people)? pickContact,
}) async {
  final off = config.offTools;
  bool on(String name) => !off.contains(_toolGroups[name] ?? name);
  final tools = <AgentTool>[
    for (final t in _builtIns(config, store, pickContact))
      if (on(t.name) && (!small || t.small)) t,
  ];
  final skills = config.onSkills;
  if (skills.isNotEmpty) tools.add(_loadSkill(skills));
  final problems = <String, String>{};
  final mcp = await pool.tools(config);
  problems.addAll(mcp.problems);
  final servers = await _toolServerTools(config);
  problems.addAll(servers.problems);
  final extra = [...mcp.tools, ...servers.tools];
  // Small models get lost with many tools; a few of yours still fit.
  if (!small || extra.length <= 8) tools.addAll(extra);
  return AgentKit(
    tools,
    agentInstructions(config, skills: skills, hasTools: tools.isNotEmpty),
    problems,
  );
}

/// The date, what the model remembers about you, and the skills it has.
String agentInstructions(
  AgentConfig config, {
  required List<Skill> skills,
  bool hasTools = true,
  DateTime? now,
}) {
  final t = now ?? DateTime.now();
  final memories = config.memoryOn ? config.memories : const [];
  return [
    'Today is ${_dateWords(t)}, ${_timeWords(t)} (${t.timeZoneName}).',
    if (hasTools)
      'You are running in the OpenAide app on the user\'s phone, with '
          'tools. Use them when they help, and say plainly what you did.',
    if (memories.isNotEmpty)
      '# What you remember about the user\n'
          '${[for (final m in memories.take(60)) '- ${m['text']}'].join('\n')}',
    if (skills.isNotEmpty) skillsInstructions(skills),
  ].join('\n\n');
}

const _days = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _dateWords(DateTime t) =>
    '${_days[t.weekday - 1]}, ${t.day} ${_months[t.month - 1]} ${t.year}';

String _timeWords(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

Map<String, dynamic> _schema(
  Map<String, Map<String, dynamic>> props, [
  List<String> required = const [],
]) => {
  'type': 'object',
  'properties': props,
  if (required.isNotEmpty) 'required': required,
};

Map<String, dynamic> _str(String description) => {
  'type': 'string',
  'description': description,
};

List<AgentTool> _builtIns(
  AgentConfig config,
  AgentStore store,
  Future<Map?> Function(List<Map> people)? pickContact,
) {
  Future<String> phone(PhoneAction action) async {
    List<Map>? offered;
    final said = await runPhoneAction(
      action,
      pick: (people) async {
        offered = people;
        return pickContact == null ? null : pickContact(people);
      },
    );
    if ((said == null || said.isEmpty) && offered != null) {
      return 'Several contacts match: '
          '${offered!.map((p) => '${p['name']} (${p['number']})').join(', ')}'
          '. Ask which one, then try again with the number.';
    }
    return said == null || said.isEmpty ? 'Nothing happened.' : said;
  }

  return [
    AgentTool(
      name: 'web_search',
      small: true,
      label: 'Searching the web',
      description:
          'Search the web for current information, news, facts, places, '
          'prices or anything you are not sure about. Returns titles, links '
          'and snippets; read a result with fetch_page for details.',
      parameters: _schema({'query': _str('What to search for')}, ['query']),
      run: (a) async {
        final q = '${a['query'] ?? ''}'.trim();
        if (q.isEmpty) return 'Give a query to search for.';
        final results = await webSearch(
          q,
          engine: config.searchEngine,
          key: config.searchKey,
          url: config.searchUrl,
        );
        return searchResultsText(q, results);
      },
    ),
    AgentTool(
      name: 'fetch_page',
      small: true,
      label: 'Reading a page',
      description:
          'Open a web page or link and read its text. Use it for links the '
          'user sends and to read search results.',
      parameters: _schema({'url': _str('The full address')}, ['url']),
      run: (a) => fetchPage('${a['url'] ?? ''}'),
    ),
    AgentTool(
      name: 'calculator',
      small: true,
      label: 'Calculating',
      description:
          'Work out maths exactly: + - * / ^ %, brackets, sqrt, sin, cos, '
          'tan, log, ln, abs, round, min, max, pi, e. Use it instead of '
          'doing arithmetic in your head.',
      parameters: _schema(
        {'expression': _str('For example (12.5 * 3) / 4 or sqrt(2)^3')},
        ['expression'],
      ),
      run: (a) async {
        final e = '${a['expression'] ?? ''}';
        try {
          return '$e = ${formatNumber(calculate(e))}';
        } on CalcException catch (x) {
          return 'Error: $x';
        }
      },
    ),
    AgentTool(
      name: 'current_time',
      small: true,
      label: 'Checking the time',
      description: 'The current date, time and time zone on the phone.',
      run: (_) async {
        final t = DateTime.now();
        return '${_dateWords(t)}, ${_timeWords(t)}, ${t.timeZoneName} '
            '(UTC${t.timeZoneOffset.isNegative ? '-' : '+'}'
            '${t.timeZoneOffset.inMinutes.abs() ~/ 60}'
            '${t.timeZoneOffset.inMinutes.abs() % 60 == 0 ? '' : ':${(t.timeZoneOffset.inMinutes.abs() % 60).toString().padLeft(2, '0')}'}). '
            'ISO: ${t.toIso8601String()}';
      },
    ),
    AgentTool(
      name: 'set_timer',
      small: true,
      label: 'Setting a timer',
      description: 'Start a countdown timer in the phone\'s clock app.',
      parameters: _schema(
        {
          'seconds': {'type': 'integer', 'description': 'Length in seconds'},
          'label': _str('What it is for'),
        },
        ['seconds'],
      ),
      run: (a) async {
        final s =
            (a['seconds'] as num?)?.round() ?? int.tryParse('${a['seconds']}');
        if (s == null || s <= 0) return 'Give the length in seconds.';
        return phone(TimerAction(s));
      },
    ),
    AgentTool(
      name: 'set_alarm',
      small: true,
      label: 'Setting an alarm',
      description: 'Set an alarm in the phone\'s clock app.',
      parameters: _schema(
        {
          'time': _str('24-hour time, like 06:30 or 18:00'),
          'label': _str('What it is for'),
        },
        ['time'],
      ),
      run: (a) async {
        final m = RegExp(r'(\d{1,2})(?::(\d{2}))?').firstMatch('${a['time']}');
        final h = int.tryParse(m?[1] ?? '');
        final min = int.tryParse(m?[2] ?? '0') ?? 0;
        if (h == null || h > 23 || min > 59) return 'Give a time like 06:30.';
        return phone(AlarmAction(h, min));
      },
    ),
    AgentTool(
      name: 'call_contact',
      small: true,
      label: 'Getting a call ready',
      description:
          'Get a phone call ready to a contact (by name) or a number. The '
          'user presses call.',
      parameters: _schema({'who': _str('A contact name or number')}, ['who']),
      run: (a) => phone(CallAction('${a['who'] ?? ''}')),
    ),
    AgentTool(
      name: 'send_text',
      small: true,
      label: 'Getting a text ready',
      description:
          'Get a text message ready to a contact or number. The user '
          'presses send.',
      parameters: _schema(
        {
          'who': _str('A contact name or number'),
          'message': _str('The text to send'),
        },
        ['who', 'message'],
      ),
      run: (a) =>
          phone(TextAction('${a['who'] ?? ''}', '${a['message'] ?? ''}')),
    ),
    AgentTool(
      name: 'open_app',
      small: true,
      label: 'Opening an app',
      description: 'Open an app on the phone by its name.',
      parameters: _schema({'name': _str('The app, like Spotify')}, ['name']),
      run: (a) async =>
          await runPhoneAction(
            OpenAppAction('${a['name'] ?? ''}'),
            pick: (_) async => null,
          ) ??
          'No app called ${a['name']} on this phone.',
    ),
    AgentTool(
      name: 'directions',
      small: true,
      label: 'Opening directions',
      description: 'Open the maps app with directions to a place.',
      parameters: _schema({'place': _str('Where to go')}, ['place']),
      run: (a) => phone(NavigateAction('${a['place'] ?? ''}')),
    ),
    AgentTool(
      name: 'flashlight',
      small: true,
      label: 'Flashlight',
      description: 'Turn the phone\'s flashlight on or off.',
      parameters: _schema({
        'on': {'type': 'boolean', 'description': 'true for on, false for off'},
      }),
      run: (a) => phone(TorchAction(a['on'] is bool ? a['on'] as bool : null)),
    ),
    AgentTool(
      name: 'add_calendar_event',
      small: true,
      label: 'Adding to the calendar',
      description:
          'Add an event to the phone\'s calendar. The calendar app opens '
          'with it filled in and the user saves it. Times are local, like '
          '2026-11-03T15:00.',
      parameters: _schema(
        {
          'title': _str('What it is'),
          'start': _str('Start, local time: YYYY-MM-DDTHH:MM, or a date'),
          'end': _str('End, local time (optional)'),
          'all_day': {'type': 'boolean', 'description': 'A whole-day event'},
          'location': _str('Where (optional)'),
          'description': _str('Notes (optional)'),
        },
        ['title', 'start'],
      ),
      run: (a) async {
        final start = DateTime.tryParse('${a['start'] ?? ''}');
        final end = DateTime.tryParse('${a['end'] ?? ''}');
        final allDay =
            a['all_day'] == true || '${a['start'] ?? ''}'.length <= 10;
        final r = await addCalendarEvent(
          title: '${a['title'] ?? 'Event'}',
          start: start?.millisecondsSinceEpoch,
          end: (end ?? start?.add(Duration(hours: allDay ? 24 : 1)))
              ?.millisecondsSinceEpoch,
          allDay: allDay,
          location: a['location'] as String?,
          description: a['description'] as String?,
        );
        return r == 'done'
            ? 'The calendar is open with "${a['title']}" filled in; the user '
                  'taps save.'
            : r;
      },
    ),
    AgentTool(
      name: 'remember',
      small: true,
      label: 'Remembering',
      description:
          'Remember a lasting fact about the user for future chats (their '
          'name, preferences, people, plans). Only when they ask, or for '
          'things clearly worth keeping.',
      parameters: _schema({'fact': _str('One short fact')}, ['fact']),
      run: (a) async {
        final fact = '${a['fact'] ?? ''}'.trim();
        if (fact.isEmpty) return 'Nothing to remember.';
        final id = await store.remember(fact);
        return 'Remembered (id $id): $fact';
      },
    ),
    AgentTool(
      name: 'forget',
      label: 'Forgetting',
      description:
          'Forget something you remembered, by its id or words from it.',
      parameters: _schema({'what': _str('The id, or words from it')}, ['what']),
      run: (a) async {
        final what = '${a['what'] ?? ''}'.toLowerCase().trim();
        final now = (await store.current()).memories;
        final hits = [
          for (final m in now)
            if (m['id'] == what ||
                (what.isNotEmpty &&
                    '${m['text']}'.toLowerCase().contains(what)))
              m,
        ];
        for (final m in hits) {
          await store.forget('${m['id']}');
        }
        return hits.isEmpty
            ? 'Nothing matched "$what".'
            : 'Forgot: ${hits.map((m) => m['text']).join('; ')}';
      },
    ),
    AgentTool(
      name: 'save_note',
      label: 'Saving a note',
      description:
          'Save a note on the phone (a list, minutes, an idea). Saving with '
          'an existing title replaces that note.',
      parameters: _schema(
        {'title': _str('Title'), 'content': _str('The note, in markdown')},
        ['title', 'content'],
      ),
      run: (a) async {
        final title = '${a['title'] ?? ''}'.trim();
        final existing = (await store.current()).notes
            .where((n) => '${n['title']}'.toLowerCase() == title.toLowerCase())
            .firstOrNull;
        await store.saveNote(
          id: existing?['id'] as String?,
          title: title,
          content: '${a['content'] ?? ''}',
        );
        return existing == null
            ? 'Saved the note "$title".'
            : 'Updated the note "$title".';
      },
    ),
    AgentTool(
      name: 'list_notes',
      label: 'Looking at notes',
      description: 'List the notes saved on the phone, newest first.',
      run: (_) async {
        final notes = [...(await store.current()).notes]
          ..sort(
            (a, b) => (b['at'] as num? ?? 0).compareTo(a['at'] as num? ?? 0),
          );
        if (notes.isEmpty) return 'No notes yet.';
        return [
          for (final n in notes.take(50))
            '- ${n['title']} (${DateTime.fromMillisecondsSinceEpoch((n['at'] as num? ?? 0).toInt()).toIso8601String().substring(0, 10)})',
        ].join('\n');
      },
    ),
    AgentTool(
      name: 'read_note',
      label: 'Reading a note',
      description: 'Read a saved note by its title.',
      parameters: _schema({'title': _str('The note\'s title')}, ['title']),
      run: (a) async {
        final t = '${a['title'] ?? ''}'.toLowerCase().trim();
        final notes = (await store.current()).notes;
        final n =
            notes
                .where((n) => '${n['title']}'.toLowerCase() == t)
                .firstOrNull ??
            notes
                .where((n) => '${n['title']}'.toLowerCase().contains(t))
                .firstOrNull;
        return n == null
            ? 'No note called "$t".'
            : '# ${n['title']}\n\n${n['content']}';
      },
    ),
  ];
}

AgentTool _loadSkill(List<Skill> skills) => AgentTool(
  name: 'load_skill',
  small: true,
  label: 'Loading a skill',
  description:
      'Load the full instructions of one of your skills before doing a task '
      'it covers. Skills: ${skills.map((s) => s.name).join(', ')}.',
  parameters: _schema(
    {
      'name': {
        'type': 'string',
        'description': 'The skill\'s name',
        'enum': [for (final s in skills) s.name],
      },
    },
    ['name'],
  ),
  run: (a) async {
    final want = '${a['name'] ?? ''}'.toLowerCase().trim();
    final s =
        skills
            .where((s) => s.name.toLowerCase() == want || s.id == want)
            .firstOrNull ??
        skills.where((s) => s.name.toLowerCase().contains(want)).firstOrNull;
    if (s == null) {
      return 'No skill called "$want". Skills: '
          '${skills.map((s) => s.name).join(', ')}';
    }
    return s.content;
  },
);

/// Your OpenAPI tool servers' tools, read fresh (they're quick).
Future<({List<AgentTool> tools, Map<String, String> problems})>
_toolServerTools(AgentConfig config) async {
  final out = <AgentTool>[];
  final problems = <String, String>{};
  final servers = [
    for (final s in config.toolServers)
      if (s['enabled'] != false) s,
  ];
  final read = await Future.wait([
    for (final s in servers)
      toolServerData({
        ...s,
        'auth_type': s['key_set'] == true ? 'bearer' : 'none',
        'key': config.secretFor('${s['id']}')['key'] ?? '',
      }).then<Object>((d) => d, onError: (Object e) => e),
  ]);
  for (final (i, s) in servers.indexed) {
    final d = read[i];
    if (d is! Map<String, dynamic>) {
      problems['${s['name'] ?? s['url']}'] = '$d';
      continue;
    }
    final slug = serverSlug(s);
    final key = config.secretFor('${s['id']}')['key'] as String?;
    for (final t in openApiTools(d['openapi'] as Map?)) {
      final op = '${t['name']}';
      out.add(
        AgentTool(
          name: toolName('${slug}__$op'),
          description: '${t['description']} (from ${s['name'] ?? slug})',
          parameters: {
            ...(t['parameters'] as Map).cast<String, dynamic>(),
            'type': 'object',
            'properties':
                (t['parameters'] as Map)['properties'] ?? <String, dynamic>{},
          },
          label: '${s['name'] ?? slug}: $op',
          run: (args) async {
            final r = await runToolServer(
              key,
              '${s['url']}',
              op,
              args,
              d['openapi'] as Map,
            );
            final result = r.first;
            return result is String ? result : jsonEncode(result);
          },
        ),
      );
    }
  }
  return (tools: out, problems: problems);
}

/// Checks an OpenAPI tool server answers: how many tools it has.
Future<int> checkToolServer(Map server, String? key) async {
  final d = await toolServerData({
    ...server,
    'auth_type': key == null || key.isEmpty ? 'none' : 'bearer',
    'key': key ?? '',
  });
  return openApiTools(d['openapi'] as Map?).length;
}
