import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'sheet.dart';
import '../../core/i18n/app_strings.dart';

/// A spreadsheet: sheet tabs, a formula bar and the grid. Every change is
/// handed up as the whole workbook in Markdown.
class SheetEditor extends StatefulWidget {
  const SheetEditor({
    super.key,
    required this.markdown,
    required this.onChanged,
    this.enabled = true,
  });

  final String markdown;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  State<SheetEditor> createState() => SheetEditorState();
}

class SheetEditorState extends State<SheetEditor> {
  late final List<Sheet> _sheets;
  int _tab = 0;
  int _r = 0;
  int _c = 0;
  final _formula = TextEditingController();
  final _focus = FocusNode();
  final _across = ScrollController();
  final _down = ScrollController();
  SheetCalc? _calc;

  static const _rowHeight = 38.0;
  static const _numberWidth = 44.0;

  Sheet get _sheet => _sheets[_tab];
  SheetCalc get _values => _calc ??= SheetCalc(_sheet);

  @override
  void initState() {
    super.initState();
    final read = sheetsFromMarkdown(widget.markdown);
    _sheets = read.isEmpty ? [Sheet(name: 'Sheet1')] : read;
    _formula.text = _sheet.cell(0, 0);
  }

  @override
  void dispose() {
    _formula.dispose();
    _focus.dispose();
    _across.dispose();
    _down.dispose();
    super.dispose();
  }

  /// The workbook as saved: empty rows and columns at the end left out.
  String get markdown =>
      sheetsToMarkdown([for (final s in _sheets) s.copy()..trim()]);

  void _changed() {
    _calc = null;
    setState(() {});
    widget.onChanged(markdown);
  }

  void _select(int r, int c, {bool edit = false}) {
    setState(() {
      _r = math.max(0, r);
      _c = math.max(0, c);
      _formula.text = _sheet.cell(_r, _c);
    });
    if (edit) {
      _focus.requestFocus();
      _formula.selection = TextSelection.collapsed(
        offset: _formula.text.length,
      );
    }
  }

  void _type(String text) {
    _sheet.set(_r, _c, text);
    _changed();
  }

  void _openTab(int i) {
    setState(() {
      _tab = i;
      _calc = null;
    });
    _select(0, 0);
  }

  Future<void> _tabMenu(int i) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const T('Rename'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const T('Duplicate'),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
            if (_sheets.length > 1)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const T('Delete this sheet'),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'rename':
        final name = TextEditingController(text: _sheets[i].name);
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: const T('Sheet name'),
            content: TextField(controller: name, autofocus: true),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const T('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(d, true),
                child: const T('Save'),
              ),
            ],
          ),
        );
        if (ok == true && name.text.trim().isNotEmpty) {
          _sheets[i].name = name.text.trim();
          _changed();
        }
      case 'copy':
        _sheets.insert(i + 1, _sheets[i].copy()..name = '${_sheets[i].name} 2');
        _changed();
        _openTab(i + 1);
      case 'delete':
        _sheets.removeAt(i);
        _changed();
        _openTab(math.min(i, _sheets.length - 1));
    }
  }

  void _rowsAndColumns(String action) {
    final s = _sheet;
    // Grow to the selected cell first, so it can be acted on.
    if (_r >= s.rows.length || _c >= s.columnCount) {
      s.set(_r, _c, s.cell(_r, _c));
    }
    switch (action) {
      case 'rowAbove':
        s.insertRow(_r);
      case 'rowBelow':
        s.insertRow(_r + 1);
        _r++;
      case 'rowDelete':
        s.removeRow(_r);
      case 'colLeft':
        s.insertColumn(_c);
      case 'colRight':
        s.insertColumn(_c + 1);
        _c++;
      case 'colDelete':
        s.removeColumn(_c);
      case 'clear':
        s.set(_r, _c, '');
    }
    _changed();
    _select(_r, _c);
  }

  double _width(int c) {
    var longest = 0;
    final calc = _values;
    for (var r = 0; r < _sheet.rows.length; r++) {
      longest = math.max(longest, calc.display(r, c).length);
    }
    return (longest * 8.5 + 20).clamp(84, 260).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = context.nexus.muted;
    final calc = _values;
    final rowCount = math.max(_sheet.rows.length + 20, 50);
    final colCount = math.max(_sheet.columnCount + 3, 8);
    final widths = [for (var c = 0; c < colCount; c++) _width(c)];
    final total = _numberWidth + widths.fold(0.0, (a, b) => a + b);
    final grid = scheme.outlineVariant.withValues(alpha: 0.6);

    Widget header(String text, double width, {bool on = false}) => Container(
      width: width,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: on ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        border: Border(
          right: BorderSide(color: grid),
          bottom: BorderSide(color: grid),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: on ? scheme.onPrimaryContainer : muted,
          fontWeight: on ? FontWeight.w600 : null,
        ),
      ),
    );

    Widget cell(int r, int c) {
      final raw = _sheet.cell(r, c);
      final shown = calc.display(r, c);
      final formula = raw.trimLeft().startsWith('=');
      final number = shown.isNotEmpty && calc.value(r, c) is double;
      final error = formula && shown.startsWith('#');
      final selected = r == _r && c == _c;
      return GestureDetector(
        onTap: widget.enabled
            ? () => selected ? _select(r, c, edit: true) : _select(r, c)
            : null,
        onDoubleTap: widget.enabled ? () => _select(r, c, edit: true) : null,
        child: Container(
          width: widths[c],
          height: _rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: number ? Alignment.centerRight : Alignment.centerLeft,
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer.withValues(alpha: 0.35)
                : r == 0
                ? scheme.surfaceContainerLow
                : null,
            border: selected
                ? Border.all(color: scheme.primary, width: 2)
                : Border(
                    right: BorderSide(color: grid),
                    bottom: BorderSide(color: grid),
                  ),
          ),
          child: Text(
            shown.replaceAll('\n', ' '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: r == 0 ? FontWeight.w600 : null,
              color: error ? scheme.error : null,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Sheet tabs.
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final (i, s) in _sheets.indexed)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onLongPress: widget.enabled ? () => _tabMenu(i) : null,
                    child: ChoiceChip(
                      label: Text(s.name),
                      selected: i == _tab,
                      onSelected: (_) => i == _tab && widget.enabled
                          ? _tabMenu(i)
                          : _openTab(i),
                    ),
                  ),
                ),
              IconButton(
                tooltip: tr('Add a sheet'),
                onPressed: widget.enabled
                    ? () {
                        _sheets.add(Sheet(name: 'Sheet${_sheets.length + 1}'));
                        _changed();
                        _openTab(_sheets.length - 1);
                      }
                    : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        // Formula bar.
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 0, 6),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${columnName(_c)}${_r + 1}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _formula,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  onChanged: _type,
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) {
                    if (_r + 1 >= rowCount) return;
                    _select(_r + 1, _c, edit: true);
                  },
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: tr('Type a value or =SUM(B2:B9)'),
                    prefixIcon: Icon(Icons.functions, size: 20, color: muted),
                    prefixIconConstraints: const BoxConstraints(minWidth: 36),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: tr('Rows and columns'),
                enabled: widget.enabled,
                icon: const Icon(Icons.table_rows_outlined),
                onSelected: _rowsAndColumns,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'rowAbove',
                    child: T('Insert row above'),
                  ),
                  PopupMenuItem(
                    value: 'rowBelow',
                    child: T('Insert row below'),
                  ),
                  PopupMenuItem(value: 'rowDelete', child: T('Delete row')),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'colLeft',
                    child: T('Insert column left'),
                  ),
                  PopupMenuItem(
                    value: 'colRight',
                    child: T('Insert column right'),
                  ),
                  PopupMenuItem(value: 'colDelete', child: T('Delete column')),
                  PopupMenuDivider(),
                  PopupMenuItem(value: 'clear', child: T('Clear cell')),
                ],
              ),
            ],
          ),
        ),
        // The grid: the column letters stay on top while rows scroll.
        Expanded(
          child: Scrollbar(
            controller: _across,
            child: SingleChildScrollView(
              controller: _across,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: total,
                child: Column(
                  children: [
                    Row(
                      children: [
                        header('', _numberWidth),
                        for (var c = 0; c < colCount; c++)
                          header(columnName(c), widths[c], on: c == _c),
                      ],
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: _down,
                        itemCount: rowCount,
                        itemExtent: _rowHeight,
                        padding: const EdgeInsets.only(bottom: 96),
                        itemBuilder: (_, r) => Row(
                          children: [
                            Container(
                              width: _numberWidth,
                              height: _rowHeight,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: r == _r
                                    ? scheme.primaryContainer
                                    : scheme.surfaceContainerHigh,
                                border: Border(
                                  right: BorderSide(color: grid),
                                  bottom: BorderSide(color: grid),
                                ),
                              ),
                              child: Text(
                                '${r + 1}',
                                style: TextStyle(fontSize: 12, color: muted),
                              ),
                            ),
                            for (var c = 0; c < colCount; c++) cell(r, c),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
