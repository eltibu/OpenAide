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

/// The longest tool result sent back, so one page can't fill the context;
/// models on the phone have much smaller contexts.
const maxToolOutput = 24000;
const maxPromptToolOutput = 4000;

/// Runs [turn] with [tools] until the model answers without calling one,
/// or [maxSteps] rounds of tools have run.
Stream<AgentEvent> runAgent({
  required ModelTurn turn,
  required List<AiMessage> messages,
  String? system,
  List<AgentTool> tools = const [],
  bool nativeTools = true,
  int maxSteps = 12,
  // Longer than an MCP call's own 120 seconds, so the server's answer
  // (or its error) arrives first.
  Duration toolTimeout = const Duration(seconds: 130),
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
  final done = <String, String>{};
  for (var step = 0; step <= maxSteps; step++) {
    final text = StringBuffer();
    final said = StringBuffer();
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
        said.write(c.text);
        final shown = parser == null ? c.text : parser.add(c.text);
        text.write(shown);
        if (shown.isNotEmpty) yield AgentText(shown);
        // Small models don't stop after a call: they go on to write a
        // made-up result and answer. Stopping here also stops the model.
        if (parser != null && parser.calls.isNotEmpty) break;
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
    if (parser != null && made.isEmpty) {
      // Written some other way: <set_alarm {...}>, {"directions": {...}}.
      final loose = looseCall(said.toString(), tools);
      if (loose != null) {
        made.add(AiToolCall('call_${++callCount}', loose.$1, loose.$2));
      } else if (parser.unread > 0 && step < maxSteps) {
        // A call it meant but got wrong: show it how, and let it try again.
        made.add(AiToolCall('call_${++callCount}', 'tool_call', '{}'));
      }
    }
    if (made.isEmpty || step == maxSteps) return;
    final results = <String>[];
    for (final c in made) {
      yield AgentToolStart(c.id, c.name, c.arguments);
      final tool =
          byName[c.name] ?? (nativeTools ? null : _closest(c.name, tools));
      final again =
          '${tool?.name ?? c.name} ${jsonEncode(_plainKeys(toolArguments(c.arguments)))}';
      String output;
      var failed = false;
      if (c.name == 'tool_call' && tool == null) {
        output =
            "That tool call couldn't be read. Write it exactly like this: "
            '<tool_call>{"name": "tool_name", "arguments": {"arg": "value"}}'
            '</tool_call>';
        failed = true;
      } else if (!nativeTools && done.containsKey(again)) {
        // Small models repeat a call that worked.
        output =
            'Already done: ${done[again]} Answer the user now; '
            "don't call it again.";
      } else if (tool == null) {
        output = 'There is no tool called ${c.name}.';
        failed = true;
      } else {
        try {
          output = await tool
              .run(_plainKeys(toolArguments(c.arguments)))
              .timeout(toolTimeout);
        } on TimeoutException {
          // The call may still finish (an email sent, a file written), so
          // the model must not try it again on its own.
          output =
              "${c.name} didn't answer in time. It may still finish, so "
              "don't run it again unless the user asks.";
          failed = true;
        } catch (e) {
          output = 'Error: $e';
          failed = true;
        }
      }
      final most = nativeTools ? maxToolOutput : maxPromptToolOutput;
      if (output.length > most) {
        output =
            '${output.substring(0, most)}\n\n'
            '[Cut: ${output.length - most} more characters]';
      }
      if (!failed) done[again] = output;
      results.add(output);
      yield AgentToolDone(c.id, output, failed: failed);
    }
    turns.add(AiToolTurn(text.toString(), made, results));
  }
}

/// A call written without the tags, found by a tool's name: the JSON
/// right after `<set_alarm`, `{"directions": {...}}`, or a JSON call with
/// a name. Only names of [tools] (or skills) count.
(String, String)? looseCall(String text, List<AgentTool> tools) {
  bool known(String name) => _closest(name, tools) != null;
  for (var i = text.indexOf('{'); i >= 0; i = text.indexOf('{', i + 1)) {
    final body = _balanced(text, i);
    if (body == null) continue;
    final v =
        ToolCallParser._json(body) ??
        ToolCallParser._json(ToolCallParser._repaired(body));
    if (v is! Map) continue;
    if (v['name'] is String && known('${v['name']}')) {
      var args = v['arguments'] ?? v['parameters'] ?? const {};
      if (args is String) args = toolArguments(args);
      return ('${v['name']}', jsonEncode(args));
    }
    if (v.length == 1 && v.values.first is Map && known('${v.keys.first}')) {
      return ('${v.keys.first}', jsonEncode(v.values.first));
    }
    // The name just before it: <set_alarm {...}>, <calculator>{...}.
    final before = text.substring((i - 48).clamp(0, i), i);
    final m = RegExp(r'([A-Za-z][\w-]*)\W{0,3}$').firstMatch(before);
    if (m != null && m[1] != 'tool_call' && known(m[1]!)) {
      return (m[1]!, jsonEncode(v));
    }
  }
  return null;
}

/// The JSON object that starts at [start], to its matching brace.
String? _balanced(String s, int start) {
  var depth = 0;
  var inString = false;
  for (var i = start; i < s.length; i++) {
    final ch = s[i];
    if (inString) {
      if (ch == r'\') {
        i++;
      } else if (ch == '"') {
        inString = false;
      }
    } else if (ch == '"') {
      inString = true;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}' && --depth == 0) {
      return s.substring(start, i + 1);
    }
  }
  return null;
}

String _squash(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Small models misspell names ("home_get_state" for "home__get_state")
/// and call a skill as if it were a tool.
AgentTool? _closest(String name, List<AgentTool> tools) {
  final want = _squash(name);
  for (final t in tools) {
    if (_squash(t.name) == want) return t;
  }
  final skill = tools.where((t) => t.name == 'load_skill').firstOrNull;
  final names =
      (skill?.parameters['properties']?['name']?['enum'] as List?) ?? const [];
  for (final n in names) {
    if (_squash('$n') == want) {
      return AgentTool(
        name: skill!.name,
        description: skill.description,
        run: (_) => skill.run({'name': n}),
      );
    }
  }
  return null;
}

/// Argument names without the marks models copy from the list ("label?").
Map<String, dynamic> _plainKeys(Map<String, dynamic> args) => {
  for (final e in args.entries) e.key.replaceAll(RegExp(r'\?$'), ''): e.value,
};

class _Call {
  String? id;
  String name = '';
  final arguments = StringBuffer();
}

/// The instructions that teach a model without tool calling to use tools.
String promptToolInstructions(List<AgentTool> tools) {
  final list = [
    for (final t in tools)
      '- ${t.name}: ${_firstSentence(t.description)}\n'
          '  arguments: ${jsonEncode(_compactSchema(t.parameters))}',
  ].join('\n');
  return '# Tools\n\n'
      'You can use these tools:\n$list\n\n'
      'To use one, write only this and stop:\n'
      '<tool_call>{"name": "tool_name", "arguments": {"arg": "value"}}'
      '</tool_call>\n'
      'The result comes back in <tool_response>. Then answer the user '
      'normally. Use a tool only when it helps; never make up a result.'
      '${tools.any((t) => t.name == 'web_search') ? '\n$liveDataRule' : ''}';
}

/// What you know stops at your training: anything that changes is looked
/// up, never answered with "I don't have live data".
const liveDataRule =
    'What you know is from your training and may be out of date. For '
    'anything that can change (who holds an office or job, news, prices, '
    'weather, scores, releases, opening hours), call web_search first and '
    "answer from the results. Never say you can't get live or current "
    'information: you can, with web_search.';

/// Small models get each tool's first sentence only.
String _firstSentence(String text) {
  final m = RegExp(r'^.*?[.!?](?=\s|$)', dotAll: true).firstMatch(text);
  return (m?[0] ?? text).trim();
}

/// Just the argument names, types and what they're for, to keep the
/// instructions short for small models.
Map<String, dynamic> _compactSchema(Map<String, dynamic> schema) {
  final props = schema['properties'];
  if (props is! Map || props.isEmpty) return {};
  final required = {...?(schema['required'] as List?)};
  return {
    for (final e in props.entries)
      '${e.key}': [
        if (e.value is Map && (e.value as Map)['type'] != null)
          '${(e.value as Map)['type']}',
        if (!required.contains(e.key)) 'optional',
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
          '<tool_response>\n'
              '${c.name}: ${i < t.results.length ? t.results[i] : ''}\n'
              '</tool_response>',
      ].join('\n'),
    ),
  ],
];

/// Takes `<tool_call>` blocks out of a streaming reply: what [add] returns
/// is the text to show, and [calls] the calls found. Gemma writes them as a
/// ```tool_call code block, so that counts too.
class ToolCallParser {
  static const _tags = [
    ('<tool_call>', '</tool_call>'),
    ('```tool_call', '```'),
  ];

  final _pending = StringBuffer();
  final calls = <(String, String)>[];

  /// Blocks that looked like calls but couldn't be read.
  int unread = 0;
  String? _close;

  String add(String chunk) {
    _pending.write(chunk);
    final out = StringBuffer();
    while (true) {
      final s = _pending.toString();
      final close = _close;
      if (close != null) {
        final end = s.indexOf(close);
        if (end < 0) return out.toString();
        _found(s.substring(0, end));
        _close = null;
        _reset(s.substring(end + close.length));
        // What a small model writes after its call is a guess at the
        // result; the real one comes next turn.
        if (calls.isNotEmpty) {
          _pending.clear();
          return out.toString();
        }
        continue;
      }
      (int, String, String)? first;
      for (final (open, close) in _tags) {
        final i = s.indexOf(open);
        if (i >= 0 && (first == null || i < first.$1)) first = (i, open, close);
      }
      if (first != null) {
        out.write(s.substring(0, first.$1));
        _close = first.$3;
        _reset(s.substring(first.$1 + first.$2.length));
        continue;
      }
      // Keep back what could be the start of a tag.
      var keep = 0;
      for (final (open, _) in _tags) {
        for (var n = open.length - 1; n > keep; n--) {
          if (s.endsWith(open.substring(0, n))) {
            keep = n;
            break;
          }
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
    if (_close != null) {
      _found(s);
      _close = null;
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
    final v = _json(b) ?? _json(_repaired(b));
    if (v is! Map) {
      unread++;
      return;
    }
    if (v['name'] is! String) {
      // {"directions": {"place": "airport"}}
      if (v.length == 1 && v.values.first is Map) {
        calls.add(('${v.keys.first}', jsonEncode(v.values.first)));
      } else {
        unread++;
      }
      return;
    }
    var args = v['arguments'] ?? v['parameters'] ?? const {};
    if (args is String) args = toolArguments(args);
    calls.add(('${v['name']}', jsonEncode(args)));
  }

  static Object? _json(String s) {
    try {
      return jsonDecode(s);
    } on FormatException {
      return null;
    }
  }

  /// Mistakes small models make: `{"calculator", "arguments": {...}}`,
  /// `{"directions", "place": "airport"}`, a stray quote after a value.
  static String _repaired(String b) {
    b = b.replaceAllMapped(
      RegExp(r'(true|false|null)"(?=\s*[,}])'),
      (m) => m[1]!,
    );
    final bare = RegExp(r'^\{\s*"([^"]+)"\s*,\s*([\s\S]*)\}$').firstMatch(b);
    if (bare == null) return b;
    final rest = bare[2]!.trim();
    final args =
        rest.startsWith('"arguments"') || rest.startsWith('"parameters"')
        ? rest
        : rest.startsWith('{')
        ? '"arguments": $rest'
        : '"arguments": {$rest}';
    return '{"name": ${jsonEncode(bare[1])}, $args}';
  }
}
