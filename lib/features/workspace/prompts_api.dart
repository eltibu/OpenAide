import 'dart:convert';

import '../../core/api/openwebui_client.dart';

/// A saved prompt, typed in chat as `/command`.
class Prompt {
  const Prompt({
    required this.id,
    required this.command,
    required this.name,
    required this.content,
    this.active = true,
    this.tags = const [],
  });

  factory Prompt.fromJson(Map j) => Prompt(
    id: '${j['id'] ?? j['command']}',
    command: '${j['command'] ?? ''}'.replaceFirst(RegExp('^/'), ''),
    name: '${j['name'] ?? j['title'] ?? ''}',
    content: '${j['content'] ?? ''}',
    active: j['is_active'] != false,
    tags: [for (final t in (j['tags'] as List? ?? const [])) '$t'],
  );

  final String id;
  final String command;
  final String name;
  final String content;
  final bool active;
  final List<String> tags;
}

class PromptsApi {
  PromptsApi(this.client);
  final OpenWebUiClient client;

  static const _base = '/api/v1/prompts';
  String _id(String id) => '$_base/id/${Uri.encodeComponent(id)}';

  /// The prompts that can be used now ("/" in chat).
  Future<List<Prompt>> active() async {
    final res = await client.send('GET', '$_base/');
    return [
      for (final p in (res as List? ?? const []).whereType<Map>())
        Prompt.fromJson(p),
    ]..sort((a, b) => a.command.compareTo(b.command));
  }

  /// Every prompt the person can see, including ones turned off.
  Future<List<Prompt>> list() async {
    final out = <Prompt>[];
    for (var page = 1; page < 20; page++) {
      final res = await client.send(
        'GET',
        '$_base/list',
        query: {'page': '$page'},
      ) as Map;
      final items = (res['items'] as List? ?? const []).whereType<Map>();
      out.addAll(items.map(Prompt.fromJson));
      if (items.isEmpty || out.length >= ((res['total'] as num?) ?? 0)) break;
    }
    return out..sort((a, b) => a.command.compareTo(b.command));
  }

  Future<void> save(
    String? id, {
    required String command,
    required String name,
    required String content,
    List<String> tags = const [],
  }) => client.send(
    'POST',
    id == null ? '$_base/create' : '${_id(id)}/update',
    body: {'command': command, 'name': name, 'content': content, 'tags': tags},
  );

  Future<void> toggle(String id) => client.send('POST', '${_id(id)}/toggle');
  Future<void> delete(String id) => client.send('DELETE', '${_id(id)}/delete');
}

/// What a `{{name | type:prop=value}}` placeholder asks for.
class PromptVariable {
  const PromptVariable(this.name, this.type, this.props);
  final String name;

  /// text, textarea, select, number, checkbox, date, … as on the web.
  final String type;
  final Map<String, Object?> props;

  String? get placeholder => props['placeholder'] as String?;
  bool get required => props['required'] == true;
  Object? get initial => props['default'];
  List<String> get options => [
    for (final o in (props['options'] as List? ?? const [])) '$o',
  ];
}

final _typed = RegExp(r'{{\s*([^|}\s]+)\s*\|\s*([^}]+)\s*}}');
final _plain = RegExp(r'{{\s*([^|}\s]+)\s*}}');

/// The `{{…}}` values the web fills in itself.
const systemVariables = {
  'CLIPBOARD',
  'USER_LOCATION',
  'USER_NAME',
  'USER_EMAIL',
  'USER_BIO',
  'USER_GENDER',
  'USER_BIRTH_DATE',
  'USER_AGE',
  'USER_LANGUAGE',
  'CURRENT_DATE',
  'CURRENT_TIME',
  'CURRENT_DATETIME',
  'CURRENT_TIMEZONE',
  'CURRENT_WEEKDAY',
};

/// Splits on [delimiter] outside quotes and brackets, as the web does.
List<String> _split(String s, String delimiter) {
  final out = <String>[];
  final cur = StringBuffer();
  var depth = 0;
  var quoted = false;
  var escape = false;
  for (final ch in s.split('')) {
    if (escape) {
      cur.write(ch);
      escape = false;
      continue;
    }
    if (ch == r'\') {
      cur.write(ch);
      escape = true;
      continue;
    }
    if (ch == '"') {
      quoted = !quoted;
      cur.write(ch);
      continue;
    }
    if (!quoted) {
      if (ch == '{' || ch == '[') depth++;
      if (ch == '}' || ch == ']') depth--;
      if (ch == delimiter && depth == 0) {
        out.add(cur.toString().trim());
        cur.clear();
        continue;
      }
    }
    cur.write(ch);
  }
  if (cur.toString().trim().isNotEmpty) out.add(cur.toString().trim());
  return out;
}

Object? _value(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    return raw.startsWith('"') && raw.endsWith('"') && raw.length > 1
        ? raw.substring(1, raw.length - 1)
        : raw;
  }
}

/// The placeholders a prompt asks the person to fill, in order.
List<PromptVariable> inputVariables(String text) {
  final found = <String, PromptVariable>{};
  for (final m in _typed.allMatches(text)) {
    final parts = _split(m[2]!.trim(), ':');
    final first = parts.isEmpty ? 'text' : parts.first;
    final props = <String, Object?>{};
    for (final p in parts.skip(1)) {
      final kv = _split(p, '=');
      if (kv.length == 1) {
        props[kv.first] = true;
      } else {
        props[kv.first.trim()] = _value(kv.skip(1).join('='));
      }
    }
    found[m[1]!.trim()] = PromptVariable(
      m[1]!.trim(),
      first.startsWith('type=') ? first.substring(5) : first,
      props,
    );
  }
  for (final m in _plain.allMatches(text)) {
    final name = m[1]!.trim();
    if (!systemVariables.contains(name)) {
      found.putIfAbsent(name, () => PromptVariable(name, 'text', const {}));
    }
  }
  return found.values.toList();
}

/// Fills the values the app knows, as the web does when a prompt is picked.
String fillSystemVariables(
  String text, {
  String? userName,
  String? userEmail,
  String? clipboard,
  String language = 'en-US',
  DateTime? now,
}) {
  final t = now ?? DateTime.now();
  String two(int v) => '$v'.padLeft(2, '0');
  final date = '${t.year}-${two(t.month)}-${two(t.day)}';
  final time = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  const weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  return text
      .replaceAll('{{USER_NAME}}', userName ?? 'User')
      .replaceAll('{{USER_EMAIL}}', userEmail ?? '{{USER_EMAIL}}')
      .replaceAll('{{CLIPBOARD}}', clipboard ?? '')
      .replaceAll('{{USER_LANGUAGE}}', language)
      .replaceAll('{{CURRENT_DATE}}', date)
      .replaceAll('{{CURRENT_TIME}}', time)
      .replaceAll('{{CURRENT_DATETIME}}', '$date $time')
      .replaceAll('{{CURRENT_TIMEZONE}}', t.timeZoneName)
      .replaceAll('{{CURRENT_WEEKDAY}}', weekdays[t.weekday - 1]);
}

/// Puts the person's answers in place of the placeholders.
String fillInputVariables(String text, Map<String, String> values) => text
    .replaceAllMapped(_typed, (m) => values[m[1]!.trim()] ?? m[0]!)
    .replaceAllMapped(_plain, (m) => values[m[1]!.trim()] ?? m[0]!);
