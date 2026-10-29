/// The web's formatting toolbar for the message box (Settings > Interface >
/// Formatting toolbar): headings, bold, italic, underline, strikethrough,
/// code, lists and emoji, written as Markdown around the selection.
library;

import 'package:flutter/material.dart';

import 'emoji.dart';

/// Wraps the selection in [open] and [close] (or takes them off when it
/// already has them). With nothing selected the cursor lands between them.
TextEditingValue wrapSelection(
  TextEditingValue v,
  String open, [
  String? close,
]) {
  close ??= open;
  final text = v.text;
  final sel = v.selection.isValid
      ? v.selection
      : TextSelection.collapsed(offset: text.length);
  final start = sel.start, end = sel.end;
  final picked = text.substring(start, end);
  // Already wrapped: unwrap.
  if (start >= open.length &&
      end + close.length <= text.length &&
      text.substring(start - open.length, start) == open &&
      text.substring(end, end + close.length) == close) {
    final out = text
        .replaceRange(end, end + close.length, '')
        .replaceRange(start - open.length, start, '');
    return TextEditingValue(
      text: out,
      selection: TextSelection(
        baseOffset: start - open.length,
        extentOffset: end - open.length,
      ),
    );
  }
  final out = text.replaceRange(start, end, '$open$picked$close');
  return TextEditingValue(
    text: out,
    selection: TextSelection(
      baseOffset: start + open.length,
      extentOffset: end + open.length,
    ),
  );
}

/// Changes each selected line with [edit] (headings, lists, indents).
TextEditingValue editLines(
  TextEditingValue v,
  String Function(String line, int index) edit,
) {
  final text = v.text;
  final sel = v.selection.isValid
      ? v.selection
      : TextSelection.collapsed(offset: text.length);
  final from = text.lastIndexOf('\n', sel.start == 0 ? 0 : sel.start - 1) + 1;
  final nl = text.indexOf('\n', sel.end);
  final to = nl < 0 ? text.length : nl;
  final lines = text.substring(from, to).split('\n');
  final changed = [for (final (i, l) in lines.indexed) edit(l, i)].join('\n');
  final out = text.replaceRange(from, to, changed);
  return TextEditingValue(
    text: out,
    selection: TextSelection.collapsed(offset: from + changed.length),
  );
}

final _listMark = RegExp(r'^(\s*)(?:[-*] \[[ xX]\] |[-*] |\d+\. )');
final _heading = RegExp(r'^#{1,6} ');

/// A heading of [level], or plain text when the line already is one.
String headingLine(String line, int level) {
  final mark = '${'#' * level} ';
  final bare = line.replaceFirst(_heading, '');
  return line.startsWith(mark) ? bare : '$mark$bare';
}

/// A list line of [kind] ('-', '1.', '- [ ]'), or plain again.
String listLine(String line, int index, String kind) {
  final m = _listMark.firstMatch(line);
  final indent = m?.group(1) ?? '';
  final bare = m == null ? line : line.substring(m.end);
  final mark = kind == '1.' ? '${index + 1}. ' : '$kind ';
  final had = m != null && line.substring(indent.length, m.end) == mark;
  return had ? '$indent$bare' : '$indent$mark$bare';
}

/// When the toolbar shows, as the web's bubble and floating menus: text is
/// selected, or the cursor sits on an empty line under some text.
bool formattingToolbarWanted(TextEditingValue v) {
  final sel = v.selection;
  if (!sel.isValid) return false;
  if (!sel.isCollapsed) return true;
  final text = v.text;
  if (text.trim().isEmpty) return false;
  final at = sel.baseOffset.clamp(0, text.length);
  final start = text.lastIndexOf('\n', at == 0 ? 0 : at - 1);
  final end = text.indexOf('\n', at);
  final line = text.substring(start + 1, end < 0 ? text.length : end);
  return start >= 0 && line.isEmpty;
}

class FormattingToolbar extends StatelessWidget {
  const FormattingToolbar({
    super.key,
    required this.controller,
    this.onChanged,
  });
  final TextEditingController controller;

  /// After a button changed the text (a TextField's onChanged doesn't run).
  final VoidCallback? onChanged;

  void _apply(TextEditingValue Function(TextEditingValue) f) {
    controller.value = f(controller.value);
    onChanged?.call();
  }

  Future<void> _emoji(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: GridView.count(
          crossAxisCount: 8,
          padding: const EdgeInsets.all(8),
          children: [
            for (final (_, e) in emojiShortcodes)
              InkWell(
                onTap: () => Navigator.pop(c, e),
                child: Center(
                  child: Text(e, style: const TextStyle(fontSize: 24)),
                ),
              ),
          ],
        ),
      ),
    );
    if (picked != null) _apply((v) => wrapSelection(v, picked, ''));
  }

  @override
  Widget build(BuildContext context) {
    Widget b(String tip, IconData icon, VoidCallback onTap) => IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      onPressed: onTap,
      icon: Icon(icon),
    );
    Widget t(String tip, String label, VoidCallback onTap) => IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
      icon: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          for (final level in [1, 2, 3])
            t('H$level', 'H$level', () {
              _apply((v) => editLines(v, (l, _) => headingLine(l, level)));
            }),
          b(
            'Bold',
            Icons.format_bold,
            () => _apply((v) => wrapSelection(v, '**')),
          ),
          b(
            'Italic',
            Icons.format_italic,
            () => _apply((v) => wrapSelection(v, '*')),
          ),
          b(
            'Underline',
            Icons.format_underlined,
            () => _apply((v) => wrapSelection(v, '<u>', '</u>')),
          ),
          b(
            'Strikethrough',
            Icons.format_strikethrough,
            () => _apply((v) => wrapSelection(v, '~~')),
          ),
          b(
            'Code Block',
            Icons.code,
            () => _apply((v) => wrapSelection(v, '```\n', '\n```')),
          ),
          b(
            'Bullet List',
            Icons.format_list_bulleted,
            () => _apply((v) => editLines(v, (l, i) => listLine(l, i, '-'))),
          ),
          b(
            'Ordered List',
            Icons.format_list_numbered,
            () => _apply((v) => editLines(v, (l, i) => listLine(l, i, '1.'))),
          ),
          b(
            'Task List',
            Icons.checklist,
            () =>
                _apply((v) => editLines(v, (l, i) => listLine(l, i, '- [ ]'))),
          ),
          b(
            'Sink List',
            Icons.format_indent_increase,
            () => _apply((v) => editLines(v, (l, _) => '  $l')),
          ),
          b(
            'Lift List',
            Icons.format_indent_decrease,
            () => _apply(
              (v) => editLines(
                v,
                (l, _) => l.replaceFirst(RegExp(r'^ {1,2}|^\t'), ''),
              ),
            ),
          ),
          b('Emoji', Icons.emoji_emotions_outlined, () => _emoji(context)),
        ],
      ),
    );
  }
}
