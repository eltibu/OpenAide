/// Editing a reply that has structured output (its text, thoughts and tool
/// calls as separate items), as the web's Edit for such replies: a Visual
/// view with one row per item, or the raw JSON.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// One row of the Visual view: the items it stands for ([indices], a tool
/// call with its result), and what kind it is.
typedef OutputRow = ({
  String kind,
  String label,
  List<int> indices,
  Map item,
  Map? result,
});

const _toolNames = {
  'web_search_call': 'Search',
  'file_search_call': 'Files',
  'computer_call': 'Computer',
};

/// The rows the Visual view shows for [output], as the web groups them.
List<OutputRow> outputRows(List output) {
  final results = <String, int>{
    for (final (i, item) in output.indexed)
      if (item is Map && item['type'] == 'function_call_output')
        '${item['call_id']}': i,
  };
  return [
    for (final (i, item) in output.indexed)
      if (item is Map)
        ...switch ('${item['type'] ?? ''}') {
          'message' => [
            (
              kind: 'message',
              label: 'Text',
              indices: [i],
              item: item,
              result: null,
            ),
          ],
          'reasoning' => [
            (
              kind: 'reasoning',
              label: 'Thought',
              indices: [i],
              item: item,
              result: null,
            ),
          ],
          'function_call' => [
            (
              kind: 'function_call',
              label: '${item['name'] ?? 'Tool'}',
              indices: [i, ?results['${item['call_id']}']],
              item: item,
              result: results['${item['call_id']}'] == null
                  ? null
                  : output[results['${item['call_id']}']!] as Map,
            ),
          ],
          'open_webui:code_interpreter' => [
            (
              kind: 'code',
              label: 'Code',
              indices: [i],
              item: item,
              result: null,
            ),
          ],
          final t when _toolNames.containsKey(t) => [
            (
              kind: 'tool',
              label: _toolNames[t]!,
              indices: [i],
              item: item,
              result: null,
            ),
          ],
          _ => const <OutputRow>[],
        },
  ];
}

String messageText(Map item) => [
  for (final p in (item['content'] as List? ?? const []).whereType<Map>())
    if (p['type'] == 'output_text' || p.containsKey('text'))
      '${p['text'] ?? ''}',
].join();

String reasoningText(Map item) => [
  for (final p
      in ((item['summary'] ?? item['content']) as List? ?? const [])
          .whereType<Map>())
    if (p.containsKey('text')) '${p['text'] ?? ''}',
].join();

/// [output] with item [i]'s text set to [text], as the web's editor does.
List setMessageText(List output, int i, String text) {
  final item = Map<String, dynamic>.from(output[i] as Map);
  final first = (item['content'] as List? ?? const [])
      .whereType<Map>()
      .where((p) => p['type'] == 'output_text' || p.containsKey('text'))
      .firstOrNull;
  item['content'] = [
    {
      ...?first?.cast<String, dynamic>(),
      'type': first?['type'] ?? 'output_text',
      'text': text,
    },
  ];
  return [...output]..[i] = item;
}

List setReasoningText(List output, int i, String text) {
  final item = Map<String, dynamic>.from(output[i] as Map);
  item[item['summary'] != null ? 'summary' : 'content'] = [
    {'type': 'text', 'text': text},
  ];
  return [...output]..[i] = item;
}

List removeItems(List output, List<int> indices) => [
  for (final (i, item) in output.indexed)
    if (!indices.contains(i)) item,
];

/// What to do with the edited output: Save (in place) or Save as copy.
typedef OutputEdit = ({List output, bool asCopy});

Future<OutputEdit?> editOutput(BuildContext context, List output) =>
    Navigator.push<OutputEdit>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => OutputEditScreen(output: output),
      ),
    );

class OutputEditScreen extends StatefulWidget {
  const OutputEditScreen({super.key, required this.output});
  final List output;

  @override
  State<OutputEditScreen> createState() => _OutputEditScreenState();
}

class _OutputEditScreenState extends State<OutputEditScreen> {
  late List _output = jsonDecode(jsonEncode(widget.output)) as List;
  bool _json = false;
  String? _jsonError;
  final _jsonText = TextEditingController();

  @override
  void dispose() {
    _jsonText.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_json) {
      if (_jsonError != null) return;
      setState(() => _json = false);
    } else {
      _jsonText.text = const JsonEncoder.withIndent('  ').convert(_output);
      setState(() => _json = true);
    }
  }

  void _onJson(String text) {
    String? error;
    try {
      final parsed = jsonDecode(text);
      if (parsed is List) {
        _output = parsed;
      } else {
        error = 'Must be a JSON array';
      }
    } catch (_) {
      error = 'Invalid JSON';
    }
    setState(() => _jsonError = error);
  }

  void _done(bool asCopy) {
    if (_jsonError != null) return;
    Navigator.pop<OutputEdit>(context, (output: _output, asCopy: asCopy));
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final mono = TextStyle(fontFamily: 'monospace', fontSize: 12, color: muted);
    String pretty(Object? v) {
      if (v == null) return '';
      if (v is String) return v;
      try {
        return const JsonEncoder.withIndent('  ').convert(v);
      } catch (_) {
        return '$v';
      }
    }

    Widget row(OutputRow r) {
      final body = switch (r.kind) {
        'message' => TextFormField(
          key: ObjectKey(r.item),
          initialValue: messageText(r.item),
          minLines: 1,
          maxLines: null,
          decoration: const InputDecoration(
            hintText: 'Message text...',
            isDense: true,
          ),
          onChanged: (t) =>
              _output = setMessageText(_output, r.indices.first, t),
        ),
        'reasoning' => TextFormField(
          key: ObjectKey(r.item),
          initialValue: reasoningText(r.item),
          minLines: 1,
          maxLines: null,
          decoration: const InputDecoration(
            hintText: 'Reasoning text...',
            isDense: true,
          ),
          onChanged: (t) =>
              _output = setReasoningText(_output, r.indices.first, t),
        ),
        'function_call' => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (r.item['arguments'] != null)
              SelectableText(pretty(r.item['arguments']), style: mono),
            if (r.result != null) ...[
              const SizedBox(height: 6),
              SelectableText(pretty(r.result!['output']), style: mono),
            ],
          ],
        ),
        'code' => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (r.item['code'] != null)
              SelectableText('${r.item['code']}', style: mono),
            if (r.item['output'] != null) ...[
              const SizedBox(height: 6),
              SelectableText(pretty(r.item['output']), style: mono),
            ],
          ],
        ),
        _ => Text(
          [
            ...?((r.item['action'] as Map?)?['queries'] as List?),
            ...?(r.item['queries'] as List?),
          ].join(', '),
          style: TextStyle(color: muted),
        ),
      };
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 76,
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  r.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: muted),
                ),
              ),
            ),
            Expanded(child: body),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              onPressed: () =>
                  setState(() => _output = removeItems(_output, r.indices)),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit reply'),
        actions: [
          Tooltip(
            message: _json
                ? 'Switch to visual editor'
                : 'Switch to JSON editor',
            child: TextButton(
              onPressed: _toggle,
              child: Text(_json ? 'JSON' : 'Visual'),
            ),
          ),
        ],
      ),
      body: _json
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _jsonText,
                expands: true,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  errorText: _jsonError,
                ),
                onChanged: _onJson,
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final r in outputRows(_output)) row(r),
                if (outputRows(_output).isEmpty)
                  Text(
                    'Nothing left in this reply.',
                    style: TextStyle(color: muted),
                  ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => _done(true),
                child: const Text('Save as copy'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _done(false),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
