/// The agent loop for models the phone talks to itself (AI providers and
/// models on the phone): the model answers or calls tools, the app runs
/// them and sends back what they returned, until the model is done.
///
/// Provider models call tools natively. Models without tool calling (the
/// small ones on the phone) get the tools in their instructions and call
/// them by writing `<tool_call>{"name": ..., "arguments": {...}}</tool_call>`,
/// the format Qwen and Hermes models are trained on.
library;

import 'dart:async';
import 'dart:convert';

import '../ai/ai_providers.dart';

/// A tool the model can use.
class AgentTool {
  const AgentTool({
    required this.name,
    required this.description,
    required this.run,
    this.parameters = const {'type': 'object', 'properties': {}},
    this.label,
    this.small = false,
  });

  /// Letters, digits, _ and - only, up to 64, as every provider requires.
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  /// What it returns for the model to read.
  final Future<String> Function(Map<String, dynamic> args) run;

  /// How the tool step reads in the reply ("Searching the web").
  final String? label;

  /// Kept for small models on the phone, which do best with a few tools.
  final bool small;

  AiToolSpec get spec => AiToolSpec(name, description, parameters);
}

/// A tool name every provider takes.
String toolName(String raw) {
  final s = raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
  final name = s.isEmpty ? 'tool' : s;
  return name.length <= 64 ? name : name.substring(0, 64);
}

sealed class AgentEvent {
  const AgentEvent();
}

class AgentText extends AgentEvent {
  const AgentText(this.text);
  final String text;
}

class AgentThinking extends AgentEvent {
  const AgentThinking(this.text);
  final String text;
}

/// The model called a tool; it's running.
class AgentToolStart extends AgentEvent {
  const AgentToolStart(this.id, this.name, this.arguments);
  final String id;
  final String name;
  final String arguments;
}

/// A tool finished.
class AgentToolDone extends AgentEvent {
  const AgentToolDone(this.id, this.output, {this.failed = false});
  final String id;
  final String output;
  final bool failed;
}

/// One turn of the model: streams what it says and returns when done.
typedef ModelTurn = Stream<AiChunk> Function({
  required List<AiMessage> messages,
  String? system,
  required List<AiToolSpec> tools,
  required List<AiToolTurn> turns,
});

/// The longest tool result sent back, so one page can't fill the context.
const maxToolOutput = 24000;

/// Runs [turn] with [tools] until the model answers without calling one,
/// or [maxSteps] rounds of tools have run.
Stream<AgentEvent> runAgent({
  required ModelTurn turn,
  required List<AiMessage> messages,
  String? system,
  List<AgentTool> tools = const [],
  bool nativeTools = true,
  int maxSteps = 12,
  Duration toolTimeout = const Duration(seconds: 90),
}) async* {
  final byName = {for (final t in tools) t.name: t};
  final turns = <AiToolTurn>[];
  final promptSystem = nativeTools || tools.isEmpty
      ? system
      : [
          if (system != null && system.trim().isNotEmpty) system.trim(),
          promptToolInstructions(tools),
        ].join('\n\n');
  var callCount = 0;
  for (var step = 0; step <= maxSteps; step++) {
    final text = StringBuffer();
    final calls = <int, _Call>{};
    final parser = nativeTools ? null : ToolCallParser();
    final stream = turn(
      messages: nativeTools ? messages : [...messages, ...promptTurns(turns)],
      system: promptSystem,
      tools: nativeTools ? [for (final t in tools) t.spec] : const [],
      turns: nativeTools ? turns : const [],
    );
    await for (final c in stream) {
      if (c.thinking.isNotEmpty) yield AgentThinking(c.thinking);
      if (c.text.isNotEmpty) {
        final shown = parser == null ? c.text : parser.add(c.text);
        text.write(shown);
        if (shown.isNotEmpty) yield AgentText(shown);
      }
      for (final d in c.tools) {
        final call = calls.putIfAbsent(d.index, _Call.new);
        if (d.id != null && d.id!.isNotEmpty) call.id = d.id!;
        if (d.name != null && d.name!.isNotEmpty) call.name += d.name!;
        call.arguments.write(d.arguments);
      }
    }
    if (parser != null) {
      final rest = parser.close();
      text.write(rest);
      if (rest.isNotEmpty) yield AgentText(rest);
    }
    final made = <AiToolCall>[
      for (final e
          in calls.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
        if (e.value.name.isNotEmpty)
          AiToolCall(
            e.value.id ?? 'call_${++callCount}',
            e.value.name,
            e.value.arguments.toString(),
          ),
      if (parser != null)
        for (final c in parser.calls)
          AiToolCall('call_${++callCount}', c.$1, c.$2),
    ];
    if (made.isEmpty || step == maxSteps) return;
    final results = <String>[];
    for (final c in made) {
      yield AgentToolStart(c.id, c.name, c.arguments);
      final tool = byName[c.name];
      String output;
      var failed = false;
      if (tool == null) {
        output = 'There is no tool called ${c.name}.';
        failed = true;
      } else {
        try {
          output = await tool
              .run(toolArguments(c.arguments))
              .timeout(toolTimeout);
        } on TimeoutException {
          output = '${c.name} took too long and was stopped.';
          failed = true;
        } catch (e) {
          output = 'Error: $e';
          failed = true;
        }
      }
      if (output.length > maxToolOutput) {
        output =
            '${output.substring(0, maxToolOutput)}\n\n'
            '[Cut: ${output.length - maxToolOutput} more characters]';
      }
      results.add(output);
      yield AgentToolDone(c.id, output, failed: failed);
    }
    turns.add(AiToolTurn(text.toString(), made, results));
  }
}

class _Call {
  String? id;
  String name = '';
  final arguments = StringBuffer();
}

/// The instructions that teach a model without tool calling to use tools.
String promptToolInstructions(List<AgentTool> tools) {
  final list = [
    for (final t in tools)
      '- ${t.name}: ${t.description}\n'
          '  arguments: ${jsonEncode(_compactSchema(t.parameters))}',
  ].join('\n');
  return '# Tools\n\n'
      'You can use these tools:\n$list\n\n'
      'To use one, write only this and stop:\n'
      '<tool_call>{"name": "tool_name", "arguments": {"arg": "value"}}'
      '</tool_call>\n'
      'The result comes back in <tool_response>. Then answer the user '
      'normally. Use a tool only when it helps; never make up a result.';
}

/// Just the argument names, types and what they're for, to keep the
/// instructions short for small models.
Map<String, dynamic> _compactSchema(Map<String, dynamic> schema) {
  final props = schema['properties'];
  if (props is! Map || props.isEmpty) return {};
  final required = {...?(schema['required'] as List?)};
  return {
    for (final e in props.entries)
      '${e.key}${required.contains(e.key) ? '' : '?'}': [
        if (e.value is Map && (e.value as Map)['type'] != null)
          '${(e.value as Map)['type']}',
        if (e.value is Map && (e.value as Map)['description'] != null)
          '${(e.value as Map)['description']}',
      ].join(', '),
  };
}

/// Tool steps written out as plain messages, for models without tool
/// calling.
List<AiMessage> promptTurns(List<AiToolTurn> turns) => [
  for (final t in turns) ...[
    AiMessage(
      'assistant',
      [
        if (t.text.trim().isNotEmpty) t.text.trim(),
        for (final c in t.calls)
          '<tool_call>${jsonEncode({'name': c.name, 'arguments': toolArguments(c.arguments)})}</tool_call>',
      ].join('\n'),
    ),
    AiMessage(
      'user',
      [
        for (final (i, c) in t.calls.indexed)
          '<tool_response name="${c.name}">\n'
              '${i < t.results.length ? t.results[i] : ''}\n'
              '</tool_response>',
      ].join('\n'),
    ),
  ],
];

/// Takes `<tool_call>` blocks out of a streaming reply: what [add] returns
/// is the text to show, and [calls] the calls found.
class ToolCallParser {
  static const _open = '<tool_call>';
  static const _close = '</tool_call>';

  final _pending = StringBuffer();
  final calls = <(String, String)>[];
  bool _inside = false;

  String add(String chunk) {
    _pending.write(chunk);
    final out = StringBuffer();
    while (true) {
      final s = _pending.toString();
      if (_inside) {
        final end = s.indexOf(_close);
        if (end < 0) return out.toString();
        _found(s.substring(0, end));
        _inside = false;
        _reset(s.substring(end + _close.length));
        continue;
      }
      final start = s.indexOf(_open);
      if (start >= 0) {
        out.write(s.substring(0, start));
        _inside = true;
        _reset(s.substring(start + _open.length));
        continue;
      }
      // Keep back what could be the start of a tag.
      var keep = 0;
      for (var n = _open.length - 1; n > 0; n--) {
        if (s.endsWith(_open.substring(0, n))) {
          keep = n;
          break;
        }
      }
      out.write(s.substring(0, s.length - keep));
      _reset(s.substring(s.length - keep));
      return out.toString();
    }
  }

  /// The end of the reply: a call left open still counts.
  String close() {
    final s = _pending.toString();
    _pending.clear();
    if (_inside) {
      _found(s);
      _inside = false;
      return '';
    }
    return s;
  }

  void _reset(String rest) {
    _pending
      ..clear()
      ..write(rest);
  }

  void _found(String body) {
    var b = body.trim();
    // Some models wrap it in a code block.
    b = b.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
    b = b.replaceFirst(RegExp(r'\s*```$'), '');
    try {
      final v = jsonDecode(b);
      if (v is! Map || v['name'] is! String) return;
      var args = v['arguments'] ?? v['parameters'] ?? const {};
      if (args is String) args = toolArguments(args);
      calls.add(('${v['name']}', jsonEncode(args)));
    } on FormatException {
      // Not a call after all.
    }
  }
}
