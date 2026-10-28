/// Compare text (/compare and the + menu): your message beside a revision,
/// the differences marked, and the one you want put back in the message
/// box, as the web's comparison.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../terminal/file_tools.dart' show DiffLine, diffTokens;

/// The differences between [a] and [b]: by line, or with [approximate] by
/// word, so a changed word in a long paragraph shows on its own.
List<DiffLine> textDiff(
  String a,
  String b, {
  bool approximate = false,
  bool ignoreSpace = false,
  bool ignoreEmphasis = false,
}) {
  String key(String s) {
    var k = s;
    if (ignoreEmphasis) k = k.replaceAll(RegExp(r'[*_~`]+'), '');
    if (ignoreSpace) k = k.replaceAll(RegExp(r'\s+'), ' ').trim();
    return k;
  }

  List<String> split(String s) => approximate
      ? RegExp(r'\s*\S+|\s+$').allMatches(s).map((m) => m[0]!).toList()
      : s.split('\n');
  return diffTokens(split(a), split(b), key: key);
}

/// Diff lines as rows of (before, after): unchanged lines on both sides,
/// each run of removed lines facing the added lines that follow it.
List<(DiffLine?, DiffLine?)> sideBySide(List<DiffLine> lines) {
  final rows = <(DiffLine?, DiffLine?)>[];
  var i = 0;
  while (i < lines.length) {
    if (lines[i].kind == ' ') {
      rows.add((lines[i], lines[i]));
      i++;
      continue;
    }
    final gone = <DiffLine>[];
    final added = <DiffLine>[];
    while (i < lines.length && lines[i].kind == '-') {
      gone.add(lines[i++]);
    }
    while (i < lines.length && lines[i].kind == '+') {
      added.add(lines[i++]);
    }
    for (var j = 0; j < gone.length || j < added.length; j++) {
      rows.add((
        j < gone.length ? gone[j] : null,
        j < added.length ? added[j] : null,
      ));
    }
  }
  return rows;
}

class CompareTextScreen extends StatefulWidget {
  const CompareTextScreen({super.key, this.original = '', this.revision = ''});
  final String original;
  final String revision;

  @override
  State<CompareTextScreen> createState() => _CompareTextScreenState();
}

class _CompareTextScreenState extends State<CompareTextScreen> {
  late final _a = TextEditingController(text: widget.original);
  late final _b = TextEditingController(text: widget.revision);
  bool _comparing = false;
  bool _approximate = false;
  bool _ignoreSpace = false;
  bool _ignoreEmphasis = false;
  bool _onlyChanges = false;
  bool _sideBySide = false;

  @override
  void initState() {
    super.initState();
    _comparing = widget.original.isNotEmpty && widget.revision.isNotEmpty;
  }

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  void _use(String text) => Navigator.pop(context, text);

  Future<void> _close() async {
    final changed = _a.text != widget.original || _b.text != widget.revision;
    if (!changed) return Navigator.pop(context);
    final leave = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        content: const Text(
          'Your comparison changes will be discarded. Your prompt will stay '
          'unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = textDiff(
      _a.text,
      _b.text,
      approximate: _approximate,
      ignoreSpace: _ignoreSpace,
      ignoreEmphasis: _ignoreEmphasis,
    );
    final added = lines.where((l) => l.kind == '+').length;
    final removed = lines.where((l) => l.kind == '-').length;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: _close,
          ),
          title: const Text('Compare text'),
          actions: [
            IconButton(
              tooltip: 'Swap',
              icon: const Icon(Icons.swap_horiz),
              onPressed: () => setState(() {
                final t = _a.text;
                _a.text = _b.text;
                _b.text = t;
              }),
            ),
            PopupMenuButton<String>(
              tooltip: 'Options',
              onSelected: (v) => setState(() {
                switch (v) {
                  case 'approx':
                    _approximate = !_approximate;
                  case 'space':
                    _ignoreSpace = !_ignoreSpace;
                  case 'emphasis':
                    _ignoreEmphasis = !_ignoreEmphasis;
                  case 'changes':
                    _onlyChanges = !_onlyChanges;
                  case 'side':
                    _sideBySide = !_sideBySide;
                }
              }),
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: 'approx',
                  checked: _approximate,
                  child: const Text('Approximate comparison'),
                ),
                CheckedPopupMenuItem(
                  value: 'space',
                  checked: _ignoreSpace,
                  child: const Text('Ignore whitespace'),
                ),
                CheckedPopupMenuItem(
                  value: 'emphasis',
                  checked: _ignoreEmphasis,
                  child: const Text('Ignore emphasis markers'),
                ),
                CheckedPopupMenuItem(
                  value: 'changes',
                  checked: _onlyChanges,
                  child: const Text('Only show changes'),
                ),
                CheckedPopupMenuItem(
                  value: 'side',
                  checked: _sideBySide,
                  child: const Text('Side by side'),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Edit')),
                  ButtonSegment(value: true, label: Text('Compare')),
                ],
                selected: {_comparing},
                onSelectionChanged: (v) => setState(() => _comparing = v.first),
              ),
            ),
            Expanded(
              child: _comparing
                  ? _diff(lines, added, removed, scheme)
                  : ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        _pane('Original', _a),
                        const SizedBox(height: 12),
                        _pane('Proposed revision', _b),
                      ],
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _use(_a.text),
                        child: const Text('Keep original'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: _b.text.isEmpty ? null : () => _use(_b.text),
                        child: const Text('Use in prompt'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pane(String label, TextEditingController c) => TextField(
    controller: c,
    minLines: 6,
    maxLines: 14,
    onChanged: (_) => setState(() {}),
    decoration: InputDecoration(
      labelText: label,
      alignLabelWithHint: true,
      border: const OutlineInputBorder(),
      suffixIcon: IconButton(
        tooltip: 'Copy',
        icon: const Icon(Icons.copy, size: 18),
        onPressed: () => Clipboard.setData(ClipboardData(text: c.text)),
      ),
    ),
  );

  Widget _diff(
    List<DiffLine> lines,
    int added,
    int removed,
    ColorScheme scheme,
  ) {
    if (_b.text.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Paste or write a revision under Edit to compare.'),
        ),
      );
    }
    Color? color(String kind) => switch (kind) {
      '+' => Colors.green.withValues(alpha: 0.2),
      '-' => scheme.error.withValues(alpha: 0.16),
      _ => null,
    };
    final summary = Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        added == 0 && removed == 0
            ? 'No differences'
            : '$added added · $removed removed',
      ),
    );
    if (_approximate) {
      // Words flow as text, changes marked where they are.
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          summary,
          Text.rich(
            TextSpan(
              children: [
                for (final l in lines)
                  if (!_onlyChanges || l.kind != ' ')
                    TextSpan(
                      text: _onlyChanges ? '${l.text} ' : l.text,
                      style: TextStyle(
                        backgroundColor: color(l.kind),
                        decoration: l.kind == '-'
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
              ],
            ),
          ),
        ],
      );
    }
    final shown = _onlyChanges
        ? lines.where((l) => l.kind != ' ').toList()
        : lines;
    if (_sideBySide) {
      // Diff layout, as the web's split view: before on the left, after on
      // the right, changed lines facing each other.
      final rows = sideBySide(shown);
      Widget cell(DiffLine? l) => Expanded(
        child: Container(
          color: l == null ? null : color(l.kind),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Text(l?.text ?? ''),
        ),
      );
      return ListView.builder(
        itemCount: rows.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) return summary;
          final (left, right) = rows[i - 1];
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                cell(left),
                VerticalDivider(width: 1, color: scheme.outlineVariant),
                cell(right),
              ],
            ),
          );
        },
      );
    }
    return ListView.builder(
      itemCount: shown.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) return summary;
        final l = shown[i - 1];
        return Container(
          color: color(l.kind),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Text('${l.kind} ${l.text}'),
        );
      },
    );
  }
}
