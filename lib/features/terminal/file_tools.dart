/// The file browser's extras, as the web's Files panel has them: sorting,
/// hidden files, comparing two files, and reading notebooks.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import 'terminal_api.dart';
import '../../core/widgets/markdown_style.dart';

enum FileSort { name, size, modified }

/// Folders first, then by [by]; [descending] flips the order within each.
List<TerminalEntry> sortEntries(
  List<TerminalEntry> entries,
  FileSort by, {
  bool descending = false,
}) {
  int compare(TerminalEntry a, TerminalEntry b) {
    final r = switch (by) {
      FileSort.size => (a.size ?? 0).compareTo(b.size ?? 0),
      FileSort.modified => (a.modified?.millisecondsSinceEpoch ?? 0).compareTo(
        b.modified?.millisecondsSinceEpoch ?? 0,
      ),
      FileSort.name => 0,
    };
    return r != 0 ? r : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  return [...entries]..sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    final r = compare(a, b);
    return descending ? -r : r;
  });
}

/// [entries] without dot files unless [showHidden].
List<TerminalEntry> visibleEntries(
  List<TerminalEntry> entries, {
  required bool showHidden,
}) => showHidden
    ? entries
    : [
        for (final e in entries)
          if (!e.name.startsWith('.')) e,
      ];

/// One line of a comparison: ' ' in both, '-' only in the first, '+' only
/// in the second.
typedef DiffLine = ({String kind, String text});

/// The lines of [a] and [b] lined up (longest common run of lines), as the
/// web's Compare shows them. [ignoreSpace] treats lines that differ only in
/// spacing as the same.
List<DiffLine> lineDiff(String a, String b, {bool ignoreSpace = false}) =>
    diffTokens(
      const LineSplitter().convert(a),
      const LineSplitter().convert(b),
      key: ignoreSpace
          ? (s) => s.replaceAll(RegExp(r'\s+'), ' ').trim()
          : (s) => s,
    );

/// [x] and [y] lined up by their longest common run, comparing [key]s.
List<DiffLine> diffTokens(
  List<String> x,
  List<String> y, {
  required String Function(String) key,
}) {
  final kx = x.map(key).toList();
  final ky = y.map(key).toList();
  // Too big to line up: show both whole.
  if (x.length * y.length > 4000000) {
    return [
      for (final l in x) (kind: '-', text: l),
      for (final l in y) (kind: '+', text: l),
    ];
  }
  final n = x.length, m = y.length;
  final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = kx[i] == ky[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final out = <DiffLine>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (kx[i] == ky[j]) {
      out.add((kind: ' ', text: y[j]));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.add((kind: '-', text: x[i++]));
    } else {
      out.add((kind: '+', text: y[j++]));
    }
  }
  while (i < n) {
    out.add((kind: '-', text: x[i++]));
  }
  while (j < m) {
    out.add((kind: '+', text: y[j++]));
  }
  return out;
}

/// Two files side by side as one list of changes.
class CompareScreen extends StatefulWidget {
  const CompareScreen({
    super.key,
    required this.api,
    required this.first,
    required this.second,
  });
  final TerminalApi api;
  final TerminalEntry first;
  final TerminalEntry second;

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  late TerminalEntry _a = widget.first;
  late TerminalEntry _b = widget.second;
  final _text = <String, String>{};
  Object? _error;
  bool _ignoreSpace = false;
  bool _changesOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      for (final e in [_a, _b]) {
        _text[e.path] = utf8.decode(
          await widget.api.read(e.path),
          allowMalformed: true,
        );
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _text[_a.path];
    final b = _text[_b.path];
    final scheme = Theme.of(context).colorScheme;
    final lines = a == null || b == null
        ? null
        : lineDiff(a, b, ignoreSpace: _ignoreSpace);
    final shown = lines == null
        ? null
        : _changesOnly
        ? lines.where((l) => l.kind != ' ').toList()
        : lines;
    final added = lines?.where((l) => l.kind == '+').length ?? 0;
    final removed = lines?.where((l) => l.kind == '-').length ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text('${_a.name} → ${_b.name}', overflow: TextOverflow.fade),
        actions: [
          IconButton(
            tooltip: 'Swap',
            icon: const Icon(Icons.swap_horiz),
            onPressed: () => setState(() {
              final t = _a;
              _a = _b;
              _b = t;
            }),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => setState(() {
              if (v == 'space') _ignoreSpace = !_ignoreSpace;
              if (v == 'changes') _changesOnly = !_changesOnly;
            }),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'space',
                checked: _ignoreSpace,
                child: const Text('Ignore spacing'),
              ),
              CheckedPopupMenuItem(
                value: 'changes',
                checked: _changesOnly,
                child: const Text('Only changes'),
              ),
            ],
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('$_error'))
          : shown == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    added == 0 && removed == 0
                        ? 'The files are the same'
                        : '$added added · $removed removed',
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final l = shown[i];
                      final color = switch (l.kind) {
                        '+' => Colors.green.withValues(alpha: 0.18),
                        '-' => scheme.error.withValues(alpha: 0.15),
                        _ => null,
                      };
                      return Container(
                        color: color,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 1,
                        ),
                        child: Text(
                          '${l.kind} ${l.text}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12.5,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

/// A Jupyter notebook's cells: Markdown, code and what the code printed
/// (text and pictures). With [api] and [path], code cells can be run on the
/// terminal server's kernel, one at a time or all, as on the web.
class NotebookView extends StatefulWidget {
  const NotebookView({super.key, required this.source, this.api, this.path});
  final String source;
  final TerminalApi? api;
  final String? path;

  @override
  State<NotebookView> createState() => _NotebookViewState();
}

class _NotebookViewState extends State<NotebookView> {
  List<Map>? _cells;
  String? _session;
  final _running = <int>{};
  bool _stopAll = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    try {
      final nb = jsonDecode(widget.source) as Map;
      _cells = [
        for (final c in (nb['cells'] as List? ?? const []).whereType<Map>())
          {...c},
      ];
    } catch (_) {
      _cells = null;
    }
  }

  @override
  void dispose() {
    final s = _session;
    if (s != null) widget.api?.stopNotebook(s);
    super.dispose();
  }

  static String _text(Object? v) => v is List ? v.join() : '${v ?? ''}';

  Future<void> _run(int i) async {
    final api = widget.api;
    final cells = _cells;
    if (api == null || cells == null || widget.path == null) return;
    setState(() {
      _running.add(i);
      _problem = null;
    });
    try {
      _session ??= await api.startNotebook(widget.path!);
      final r = await api.runCell(_session!, i, _text(cells[i]['source']));
      if (!mounted) return;
      setState(() {
        cells[i]['outputs'] = r['outputs'] ?? const [];
        if (r['execution_count'] != null) {
          cells[i]['execution_count'] = r['execution_count'];
        }
      });
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    } finally {
      if (mounted) setState(() => _running.remove(i));
    }
  }

  Future<void> _runAll() async {
    _stopAll = false;
    final cells = _cells ?? const [];
    for (var i = 0; i < cells.length && !_stopAll && mounted; i++) {
      if (cells[i]['cell_type'] == 'code') await _run(i);
      if (_problem != null) break;
    }
  }

  Future<void> _restart() async {
    _stopAll = true;
    final s = _session;
    _session = null;
    if (s != null) await widget.api?.stopNotebook(s);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cells = _cells;
    if (cells == null) {
      return const Center(child: Text("This notebook can't be read."));
    }
    final scheme = Theme.of(context).colorScheme;
    final canRun = widget.api != null && widget.path != null;
    return Column(
      children: [
        if (canRun)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run all'),
                  onPressed: _running.isEmpty ? _runAll : null,
                ),
                if (_running.isNotEmpty)
                  TextButton.icon(
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                    onPressed: () => setState(() => _stopAll = true),
                  ),
                TextButton.icon(
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Restart'),
                  onPressed: _session == null ? null : _restart,
                ),
              ],
            ),
          ),
        if (_problem != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_problem!, style: TextStyle(color: scheme.error)),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: cells.length,
            itemBuilder: (context, i) {
              final c = cells[i];
              final src = _text(c['source']);
              if (c['cell_type'] == 'markdown') {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: MarkdownBlock(
                    data: src,
                    config: nexusMarkdown(context),
                  ),
                );
              }
              final outputs = (c['outputs'] as List? ?? const [])
                  .whereType<Map>()
                  .toList();
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          c['execution_count'] != null
                              ? 'In [${c['execution_count']}]'
                              : 'In [ ]',
                          style: TextStyle(color: scheme.primary, fontSize: 11),
                        ),
                        const Spacer(),
                        if (canRun)
                          _running.contains(i)
                              ? const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : IconButton(
                                  tooltip: 'Run cell',
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.play_arrow, size: 18),
                                  onPressed: () => _run(i),
                                ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(
                        src,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                    for (final o in outputs) _output(o, scheme),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _output(Map o, ColorScheme scheme) {
    final data = o['data'] is Map ? o['data'] as Map : const {};
    final png = data['image/png'];
    if (png != null) {
      try {
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Image.memory(
            base64Decode(_text(png).replaceAll('\n', '')),
            fit: BoxFit.contain,
          ),
        );
      } catch (_) {}
    }
    final error = o['output_type'] == 'error';
    final body = error
        ? '${o['ename']}: ${o['evalue']}'
        : _text(o['text'] ?? data['text/plain']);
    if (body.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 4),
      child: SelectableText(
        body,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: error ? scheme.error : null,
        ),
      ),
    );
  }
}
