/// A reply in the order it happened: thinking, tool calls, task steps and
/// text, read from what Open WebUI stores (`output` items, `statusHistory`,
/// or the `<details>` blocks older servers put in the text).
library;

import 'dart:convert';

import '../../core/models/chat.dart';

sealed class ReplyPart {
  const ReplyPart();
}

class TextPart extends ReplyPart {
  const TextPart(this.text);
  final String text;
}

/// A step: something the model did on the way to its answer.
sealed class StepPart extends ReplyPart {
  const StepPart({this.done = true});
  final bool done;
}

class ThinkingPart extends StepPart {
  const ThinkingPart(this.text, {this.seconds, super.done});
  final String text;

  /// How long it thought, when the server says.
  final int? seconds;
}

class ToolPart extends StepPart {
  const ToolPart({
    required this.name,
    this.arguments = '',
    this.result,
    this.failed = false,
    super.done,
  });
  final String name;
  final String arguments;
  final String? result;
  final bool failed;
}

/// A task step the server reported ("Searching the web", "Reading 3
/// pages"...).
class StatusPart extends StepPart {
  const StatusPart(this.description, {super.done});
  final String description;
}

/// Text parts as they are, steps next to each other gathered into a group.
List<Object> groupParts(List<ReplyPart> parts) {
  final out = <Object>[];
  for (final p in parts) {
    if (p is StepPart) {
      if (out.isNotEmpty && out.last is List<StepPart>) {
        (out.last as List<StepPart>).add(p);
      } else {
        out.add(<StepPart>[p]);
      }
    } else {
      out.add(p);
    }
  }
  return out;
}

/// The parts of [m], in order. A finished reply's steps all count as done.
List<ReplyPart> replyParts(ChatMessage m, {bool live = false}) {
  final steps = <ReplyPart>[
    for (final s
        in (m.extra['statusHistory'] as List? ?? const []).whereType<Map>())
      if (s['hidden'] != true && '${s['description'] ?? ''}'.trim().isNotEmpty)
        StatusPart(
          '${s['description']}'.trim(),
          done: !live || s['done'] == true,
        ),
  ];
  // While a reply runs the last task step is the one going on now.
  if (live && steps.isNotEmpty) {
    for (var i = 0; i < steps.length - 1; i++) {
      final s = steps[i] as StatusPart;
      steps[i] = StatusPart(s.description);
    }
  }
  final output = m.extra['output'];
  final body = output is List && output.isNotEmpty
      ? outputParts(output, live: live)
      : contentParts(m.content, live: live);
  // Text that came some other way than the output items.
  if (!body.any((p) => p is TextPart)) {
    body.addAll(contentParts(m.content).whereType<TextPart>());
  }
  return [...steps, ...body];
}

String _texts(Object? parts) => [
  for (final p in (parts is List ? parts : [parts]))
    if (p is Map && p['text'] is String)
      p['text'] as String
    else if (p is String)
      p,
].join('\n');

/// Parts from the server's `output` items.
List<ReplyPart> outputParts(List output, {bool live = false}) {
  final results = <String, Map>{
    for (final item in output.whereType<Map>())
      if (item['type'] == 'function_call_output') '${item['call_id']}': item,
  };
  final out = <ReplyPart>[];
  for (final item in output.whereType<Map>()) {
    switch (item['type']) {
      case 'message':
        final text = _texts(item['content']);
        if (text.trim().isEmpty) continue;
        if (out.isNotEmpty && out.last is TextPart) {
          out.last = TextPart('${(out.last as TextPart).text}\n$text');
        } else {
          out.add(TextPart(text));
        }
      case 'reasoning':
        var text = _texts(item['content']);
        if (text.trim().isEmpty) text = _texts(item['summary']);
        final status = item['status'];
        out.add(
          ThinkingPart(
            text.trim(),
            seconds: (item['duration'] as num?)?.toInt(),
            done: !live || (status != null && status != 'in_progress'),
          ),
        );
      case 'function_call':
        final r = results['${item['call_id']}'];
        final status = '${item['status'] ?? ''}';
        out.add(
          ToolPart(
            name: '${item['name'] ?? 'tool'}',
            arguments: '${item['arguments'] ?? ''}',
            result: r == null ? null : _texts(r['output']),
            failed: status == 'failed' || r?['status'] == 'failed',
            done: !live || r != null || status == 'failed',
          ),
        );
    }
  }
  return out;
}

String _unescape(String s) => s
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

final _details = RegExp(r'<details\s([^>]*)>([\s\S]*?)</details>\s*');
final _attr = RegExp(r'(\w+)="([^"]*)"');

/// Parts from a reply's text, for servers that put thinking and tool calls
/// in it as `<details>` blocks.
List<ReplyPart> contentParts(String content, {bool live = false}) {
  final out = <ReplyPart>[];
  var at = 0;
  void text(String t) {
    if (t.trim().isNotEmpty) out.add(TextPart(t.trim()));
  }

  for (final m in _details.allMatches(content)) {
    final attrs = {
      for (final a in _attr.allMatches(m.group(1)!))
        a.group(1)!: _unescape(a.group(2)!),
    };
    final type = attrs['type'];
    if (type != 'reasoning' &&
        type != 'tool_calls' &&
        type != 'code_interpreter') {
      continue;
    }
    text(content.substring(at, m.start));
    at = m.end;
    final done = !live || attrs['done'] == 'true';
    final inner = m
        .group(2)!
        .replaceFirst(RegExp(r'^\s*<summary>[\s\S]*?</summary>'), '');
    switch (type) {
      case 'reasoning':
        out.add(
          ThinkingPart(
            inner
                .split('\n')
                .map((l) => l.replaceFirst(RegExp(r'^\s*>\s?'), ''))
                .join('\n')
                .trim(),
            seconds: int.tryParse(attrs['duration'] ?? ''),
            done: done,
          ),
        );
      case 'tool_calls':
        String? result = attrs['result'];
        // The result is stored as a JSON string.
        if (result != null) {
          try {
            final v = jsonDecode(result);
            if (v is String) result = v;
          } on FormatException {
            // Kept as it is.
          }
        }
        out.add(
          ToolPart(
            name: attrs['name'] ?? 'tool',
            arguments: attrs['arguments'] ?? '',
            result: result,
            done: done,
          ),
        );
      default:
        out.add(ToolPart(name: 'Code', arguments: inner.trim(), done: done));
    }
  }
  text(content.substring(at));
  return out;
}

/// Keeps a running reply's `output` items up to date from the server's
/// live `response:completion` events, the way the web UI does.
List<Map<String, dynamic>> applyOutputEvent(
  List<Map<String, dynamic>> output,
  Map event,
) {
  final type = event['type'];
  final index = event['output_index'];
  final i = index is int
      ? index
      : output.isEmpty
      ? 0
      : output.length - 1;
  Map<String, dynamic> at(String kind) {
    while (output.length <= i) {
      output.add({
        'type': kind,
        'content': <Map<String, dynamic>>[],
        if (event['item_id'] != null) 'id': event['item_id'],
      });
    }
    return output[i];
  }

  switch (type) {
    case 'response.output_item.added' || 'response.output_item.done':
      final item = event['item'];
      if (item is! Map) break;
      final copy = jsonDecode(jsonEncode(item)) as Map<String, dynamic>;
      if (index is! int || index >= output.length) {
        output.add(copy);
      } else if (type == 'response.output_item.done' ||
          output[index]['id'] == copy['id']) {
        output[index] = copy;
      } else {
        output.insert(index, copy);
      }
    case 'response.output_text.delta' || 'response.reasoning_text.delta':
      final delta = event['delta'];
      if (delta is! String) break;
      final item = at(
        type == 'response.reasoning_text.delta' ? 'reasoning' : 'message',
      );
      final parts = (item['content'] is List)
          ? (item['content'] as List).cast<Object?>().toList()
          : <Object?>[];
      final ci = event['content_index'] is int
          ? event['content_index'] as int
          : (parts.isEmpty ? 0 : parts.length - 1);
      while (parts.length <= ci) {
        parts.add({'type': 'output_text', 'text': ''});
      }
      final p = Map<String, dynamic>.from(parts[ci] as Map);
      p['text'] = '${p['text'] ?? ''}$delta';
      parts[ci] = p;
      item['content'] = parts;
    case 'response.function_call_arguments.delta':
      if (index is! int || index >= output.length) break;
      output[index]['arguments'] =
          '${output[index]['arguments'] ?? ''}${event['delta'] ?? ''}';
    case 'response.function_call_arguments.done':
      if (index is! int || index >= output.length) break;
      if (event['arguments'] != null) {
        output[index]['arguments'] = '${event['arguments']}';
      }
  }
  return output;
}

/// A tool's name as words: `search_gmail` → "search gmail".
String toolLabel(String name) {
  final words = name
      .replaceAll(RegExp(r'[_\-]+'), ' ')
      .replaceAllMapped(
        RegExp(r'([a-z])([A-Z])'),
        (m) => '${m[1]} ${m[2]!.toLowerCase()}',
      )
      .trim();
  return words.isEmpty ? name : words;
}

/// One line for a group of steps, like "Thought for 8s, used search gmail".
String stepsSummary(List<StepPart> steps) {
  final thinking = steps.whereType<ThinkingPart>().toList();
  final tools = steps.whereType<ToolPart>().toList();
  final statuses = steps.whereType<StatusPart>().toList();
  final bits = <String>[];
  if (thinking.isNotEmpty) {
    final secs = thinking.fold<int>(0, (a, t) => a + (t.seconds ?? 0));
    bits.add(
      thinking.any((t) => !t.done)
          ? 'Thinking'
          : secs > 0
          ? 'Thought for ${_duration(secs)}'
          : 'Thought',
    );
  }
  if (tools.isNotEmpty) {
    final names = {for (final t in tools) toolLabel(t.name)}.toList();
    bits.add(
      names.length == 1
          ? 'used ${names.first}${tools.length > 1 ? ' ${tools.length} times' : ''}'
          : names.length == 2
          ? 'used ${names[0]} and ${names[1]}'
          : 'used ${tools.length} tools',
    );
  }
  if (bits.isEmpty && statuses.isNotEmpty) bits.add(statuses.last.description);
  if (bits.isEmpty) return 'Steps';
  final line = bits.join(', ');
  return line[0].toUpperCase() + line.substring(1);
}

String _duration(int secs) =>
    secs < 60 ? '${secs}s' : '${secs ~/ 60}m ${secs % 60}s';

/// What a running group is doing now, for its header.
String currentStep(List<StepPart> steps) {
  final s = steps.lastWhere((s) => !s.done, orElse: () => steps.last);
  return switch (s) {
    ThinkingPart() => 'Thinking…',
    ToolPart(:final name) => 'Using ${toolLabel(name)}…',
    StatusPart(:final description) => description,
  };
}

/// JSON shown indented; anything else as it is.
String prettyJson(String text) {
  final t = text.trim();
  if (!(t.startsWith('{') || t.startsWith('['))) return text;
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(t));
  } on FormatException {
    return text;
  }
}
