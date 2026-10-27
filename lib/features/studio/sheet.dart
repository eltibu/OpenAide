/// Spreadsheets in the Studio: sheets of cells, kept as Markdown tables so
/// the server (and Open WebUI's Notes) can read them too.
library;

import 'dart:math' as math;

/// The first line of a Studio file that isn't a plain document.
const sheetMarker = '<!-- nexus:sheet -->';
const slidesMarker = '<!-- nexus:slides -->';

/// What a Studio file is, from its text.
String studioKind(String markdown) {
  final first = markdown.trimLeft();
  if (first.startsWith(sheetMarker)) return 'sheet';
  if (first.startsWith(slidesMarker)) return 'slides';
  return 'doc';
}

class Sheet {
  Sheet({required this.name, List<List<String>>? rows})
    : rows =
          rows ??
          [for (var r = 0; r < 10; r++) List.filled(5, '', growable: true)];

  String name;

  /// Cells by row, then column. Every row has the same length.
  final List<List<String>> rows;

  int get columnCount => rows.isEmpty ? 0 : rows.first.length;

  String cell(int r, int c) =>
      r < rows.length && c < rows[r].length ? rows[r][c] : '';

  void set(int r, int c, String value) {
    while (rows.length <= r) {
      rows.add(List.filled(math.max(columnCount, c + 1), '', growable: true));
    }
    if (c >= columnCount) {
      for (final row in rows) {
        row.addAll(List.filled(c + 1 - row.length, '', growable: true));
      }
    }
    rows[r][c] = value;
  }

  // Rows and columns moving keep formulas pointing at the same cells.
  void _shift({int row = 0, int rowBy = 0, int col = 0, int colBy = 0}) {
    for (final r in rows) {
      for (var c = 0; c < r.length; c++) {
        if (r[c].trimLeft().startsWith('=')) {
          r[c] = shiftRefs(
            r[c],
            row: row,
            rowBy: rowBy,
            col: col,
            colBy: colBy,
          );
        }
      }
    }
  }

  void insertRow(int at) {
    final i = at.clamp(0, rows.length);
    rows.insert(i, List.filled(columnCount, '', growable: true));
    _shift(row: i, rowBy: 1);
  }

  void removeRow(int at) {
    if (rows.length <= 1 || at >= rows.length) return;
    rows.removeAt(at);
    _shift(row: at + 1, rowBy: -1);
  }

  void insertColumn(int at) {
    final i = at.clamp(0, columnCount);
    for (final row in rows) {
      row.insert(i.clamp(0, row.length), '');
    }
    _shift(col: i, colBy: 1);
  }

  void removeColumn(int at) {
    if (columnCount <= 1 || at >= columnCount) return;
    for (final row in rows) {
      row.removeAt(at);
    }
    _shift(col: at + 1, colBy: -1);
  }

  /// Drops empty rows and columns at the end (keeping at least one cell).
  void trim() {
    while (rows.length > 1 && rows.last.every((c) => c.trim().isEmpty)) {
      rows.removeLast();
    }
    while (columnCount > 1 && rows.every((r) => r.last.trim().isEmpty)) {
      for (final r in rows) {
        r.removeLast();
      }
    }
  }

  Sheet copy() => Sheet(
    name: name,
    rows: [
      for (final r in rows) [...r],
    ],
  );
}

/// Column letters: 0 → A, 26 → AA.
String columnName(int c) {
  var n = c + 1;
  var s = '';
  while (n > 0) {
    final m = (n - 1) % 26;
    s = String.fromCharCode(65 + m) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

int? columnIndex(String letters) {
  var n = 0;
  for (final ch in letters.toUpperCase().codeUnits) {
    if (ch < 65 || ch > 90) return null;
    n = n * 26 + (ch - 64);
  }
  return n == 0 ? null : n - 1;
}

final _cellRef = RegExp(
  r'(?<![A-Za-z0-9_.$])(\$?)([A-Za-z]{1,3})(\$?)(\d+)(?![A-Za-z0-9_(])',
);

/// A formula with its cell references moved: rows from [row] on (0-based)
/// by [rowBy], columns from [col] on by [colBy]. Text in quotes is left.
String shiftRefs(
  String formula, {
  int row = 0,
  int rowBy = 0,
  int col = 0,
  int colBy = 0,
}) {
  final parts = formula.split('"');
  for (var i = 0; i < parts.length; i += 2) {
    parts[i] = parts[i].replaceAllMapped(_cellRef, (m) {
      final c = columnIndex(m.group(2)!);
      final r = int.parse(m.group(4)!) - 1;
      if (c == null) return m.group(0)!;
      final nr = rowBy != 0 && r >= row ? math.max(0, r + rowBy) : r;
      final nc = colBy != 0 && c >= col ? math.max(0, c + colBy) : c;
      return '${m.group(1)}${columnName(nc)}${m.group(3)}${nr + 1}';
    });
  }
  return parts.join('"');
}

// ---- Markdown ----

String _escapeCell(String s) =>
    s.replaceAll('\\', '\\\\').replaceAll('|', '\\|').replaceAll('\n', '<br>');

String _unescapeCell(String s) =>
    s.replaceAll('<br>', '\n').replaceAll('\\|', '|').replaceAll('\\\\', '\\');

String _table(Sheet s) {
  final rows = s.rows.isEmpty
      ? [
          <String>[''],
        ]
      : s.rows;
  final width = rows.first.length;
  String line(List<String> cells) =>
      '| ${[for (var c = 0; c < width; c++) _escapeCell(c < cells.length ? cells[c] : '')].join(' | ')} |';
  return [
    line(rows.first),
    '|${List.filled(width, '---').join('|')}|',
    for (final r in rows.skip(1)) line(r),
  ].join('\n');
}

/// The sheets as a Studio file: the marker, then each sheet's name and
/// table. The first row of each table is the sheet's first row.
String sheetsToMarkdown(List<Sheet> sheets) => [
  sheetMarker,
  for (final s in sheets) '## ${s.name}\n\n${_table(s)}',
].join('\n\n');

List<String> _splitRow(String line) {
  var t = line.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|') && !t.endsWith('\\|')) t = t.substring(0, t.length - 1);
  final cells = <String>[];
  final cur = StringBuffer();
  for (var i = 0; i < t.length; i++) {
    final ch = t[i];
    if (ch == '\\' && i + 1 < t.length) {
      cur
        ..write(ch)
        ..write(t[i + 1]);
      i++;
    } else if (ch == '|') {
      cells.add(_unescapeCell(cur.toString().trim()));
      cur.clear();
    } else {
      cur.write(ch);
    }
  }
  cells.add(_unescapeCell(cur.toString().trim()));
  return cells;
}

final _separator = RegExp(r'^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$');

/// Reads sheets from Markdown: every table is a sheet, named by the
/// heading above it. Text that isn't a table is left out.
List<Sheet> sheetsFromMarkdown(String markdown) {
  final sheets = <Sheet>[];
  String? name;
  List<List<String>>? rows;
  void close() {
    if (rows != null && rows!.isNotEmpty) {
      final width = rows!.map((r) => r.length).reduce(math.max);
      sheets.add(
        Sheet(
          name: name ?? 'Sheet${sheets.length + 1}',
          rows: [
            for (final r in rows!)
              [...r, ...List.filled(width - r.length, '', growable: true)],
          ],
        ),
      );
    }
    rows = null;
    name = null;
  }

  for (final raw in markdown.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trim();
    if (line.startsWith('|')) {
      if (_separator.hasMatch(line)) continue;
      (rows ??= []).add(_splitRow(line));
    } else {
      if (rows != null) close();
      final h = RegExp(r'^#{1,6}\s+(.*)$').firstMatch(line);
      if (h != null) name = h.group(1)!.trim();
    }
  }
  close();
  return sheets;
}

// ---- Formulas ----

/// What a cell shows: its value, or what its formula works out to.
class SheetCalc {
  SheetCalc(this.sheet);
  final Sheet sheet;
  final _cache = <String, Object>{};
  final _busy = <String>{};

  /// The shown text of a cell.
  String display(int r, int c) {
    final raw = sheet.cell(r, c);
    // What was typed shows as typed: $3.50 stays $3.50.
    if (!raw.trimLeft().startsWith('=')) return raw;
    final v = value(r, c);
    if (v is double) return formatNumber(v);
    return '$v';
  }

  /// A number, or text (errors are text like #REF!).
  Object value(int r, int c) {
    final key = '$r:$c';
    final hit = _cache[key];
    if (hit != null) return hit;
    final raw = sheet.cell(r, c).trim();
    Object out;
    if (raw.startsWith('=') && raw.length > 1) {
      if (!_busy.add(key)) return '#CYCLE!';
      try {
        out = _Parser(raw.substring(1), this).parse();
      } on _FormulaError catch (e) {
        out = e.code;
      } finally {
        _busy.remove(key);
      }
    } else {
      out = parseNumber(raw) ?? raw;
    }
    _cache[key] = out;
    return out;
  }
}

/// A cell's text as a number: 12, 1,200.50, $3, 45%.
double? parseNumber(String s) {
  var t = s.trim();
  if (t.isEmpty) return null;
  var scale = 1.0;
  if (t.endsWith('%')) {
    scale = 0.01;
    t = t.substring(0, t.length - 1);
  }
  t = t.replaceAll(RegExp(r'^[$€£]'), '').replaceAll(',', '');
  final n = double.tryParse(t);
  return n == null ? null : n * scale;
}

String formatNumber(double v) {
  if (v.isNaN || v.isInfinite) return '#NUM!';
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  final s = v.toStringAsFixed(6);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

class _FormulaError implements Exception {
  const _FormulaError(this.code);
  final String code;
}

final _ref = RegExp(r'^\$?([A-Za-z]{1,3})\$?(\d+)$');

/// A small formula language: + - * / ^, parentheses, numbers, cells (B2),
/// ranges (B2:B9) and SUM, AVERAGE, MIN, MAX, COUNT, ROUND, ABS, IF.
class _Parser {
  _Parser(this.src, this.calc);
  final String src;
  final SheetCalc calc;
  int i = 0;

  Object parse() {
    final v = _compare();
    _space();
    if (i < src.length) throw const _FormulaError('#ERROR!');
    if (v is _Range) throw const _FormulaError('#VALUE!');
    return v;
  }

  void _space() {
    while (i < src.length && src[i] == ' ') {
      i++;
    }
  }

  bool _eat(String s) {
    _space();
    if (src.startsWith(s, i)) {
      i += s.length;
      return true;
    }
    return false;
  }

  double _num(Object v) {
    if (v is double) return v;
    if (v is String && v.startsWith('#')) throw _FormulaError(v);
    if (v is String && v.trim().isEmpty) return 0;
    if (v is String) {
      final n = parseNumber(v);
      if (n != null) return n;
    }
    throw const _FormulaError('#VALUE!');
  }

  Object _compare() {
    final a = _sum();
    for (final op in ['>=', '<=', '<>', '=', '>', '<']) {
      if (_eat(op)) {
        final b = _sum();
        final x = _num(a), y = _num(b);
        final r = switch (op) {
          '>=' => x >= y,
          '<=' => x <= y,
          '<>' => x != y,
          '=' => x == y,
          '>' => x > y,
          _ => x < y,
        };
        return r ? 1.0 : 0.0;
      }
    }
    return a;
  }

  Object _sum() {
    var v = _term();
    while (true) {
      if (_eat('+')) {
        v = _num(v) + _num(_term());
      } else if (_eat('-')) {
        v = _num(v) - _num(_term());
      } else if (_eat('&')) {
        v = '${_text(v)}${_text(_term())}';
      } else {
        return v;
      }
    }
  }

  String _text(Object v) => v is double ? formatNumber(v) : '$v';

  Object _term() {
    var v = _power();
    while (true) {
      if (_eat('*')) {
        v = _num(v) * _num(_power());
      } else if (_eat('/')) {
        final d = _num(_power());
        if (d == 0) throw const _FormulaError('#DIV/0!');
        v = _num(v) / d;
      } else {
        return v;
      }
    }
  }

  Object _power() {
    final v = _unary();
    if (_eat('^')) return math.pow(_num(v), _num(_power())).toDouble();
    return v;
  }

  Object _unary() {
    if (_eat('-')) return -_num(_unary());
    if (_eat('+')) return _num(_unary());
    final v = _atom();
    if (_eat('%')) return _num(v) / 100;
    return v;
  }

  Object _atom() {
    _space();
    if (_eat('(')) {
      final v = _compare();
      if (!_eat(')')) throw const _FormulaError('#ERROR!');
      return v;
    }
    if (_eat('"')) {
      final end = src.indexOf('"', i);
      if (end < 0) throw const _FormulaError('#ERROR!');
      final s = src.substring(i, end);
      i = end + 1;
      return s;
    }
    final m = RegExp(r'[0-9.]+').matchAsPrefix(src, i);
    if (m != null) {
      i = m.end;
      return double.tryParse(m.group(0)!) ??
          (throw const _FormulaError('#ERROR!'));
    }
    final w = RegExp(r'\$?[A-Za-z]+\$?[0-9]*').matchAsPrefix(src, i);
    if (w == null) throw const _FormulaError('#ERROR!');
    i = w.end;
    final word = w.group(0)!;
    if (_eat('(')) return _call(word.toUpperCase());
    if (_eat(':')) {
      final w2 = RegExp(r'\$?[A-Za-z]+\$?[0-9]+').matchAsPrefix(src, i);
      if (w2 == null) throw const _FormulaError('#REF!');
      i = w2.end;
      return _Range(_cellOf(word), _cellOf(w2.group(0)!));
    }
    final upper = word.toUpperCase();
    if (upper == 'TRUE') return 1.0;
    if (upper == 'FALSE') return 0.0;
    final (r, c) = _cellOf(word);
    return calc.value(r, c);
  }

  (int, int) _cellOf(String ref) {
    final m = _ref.firstMatch(ref);
    if (m == null) throw const _FormulaError('#NAME?');
    final c = columnIndex(m.group(1)!);
    final r = int.parse(m.group(2)!) - 1;
    if (c == null || r < 0) throw const _FormulaError('#REF!');
    return (r, c);
  }

  List<Object> _args() {
    final args = <Object>[];
    if (_eat(')')) return args;
    do {
      args.add(_compare());
    } while (_eat(',') || _eat(';'));
    if (!_eat(')')) throw const _FormulaError('#ERROR!');
    return args;
  }

  /// Numbers in the arguments; text cells in ranges are skipped.
  List<double> _numbers(List<Object> args) {
    final out = <double>[];
    for (final a in args) {
      if (a is _Range) {
        for (final v in a.values(calc)) {
          if (v is double) out.add(v);
          if (v is String && v.startsWith('#')) throw _FormulaError(v);
        }
      } else {
        out.add(_num(a));
      }
    }
    return out;
  }

  Object _call(String name) {
    final args = _args();
    switch (name) {
      case 'SUM':
        return _numbers(args).fold<double>(0, (a, b) => a + b);
      case 'AVERAGE' || 'AVG':
        final n = _numbers(args);
        if (n.isEmpty) throw const _FormulaError('#DIV/0!');
        return n.reduce((a, b) => a + b) / n.length;
      case 'MIN':
        final n = _numbers(args);
        return n.isEmpty ? 0.0 : n.reduce(math.min);
      case 'MAX':
        final n = _numbers(args);
        return n.isEmpty ? 0.0 : n.reduce(math.max);
      case 'COUNT':
        return _numbers(args).length.toDouble();
      case 'ROUND':
        if (args.isEmpty) throw const _FormulaError('#ERROR!');
        final places = args.length > 1 ? _num(args[1]).toInt() : 0;
        final f = math.pow(10, places);
        return (_num(args[0]) * f).roundToDouble() / f;
      case 'ABS':
        if (args.isEmpty) throw const _FormulaError('#ERROR!');
        return _num(args[0]).abs();
      case 'IF':
        if (args.isEmpty) throw const _FormulaError('#ERROR!');
        final yes = _num(args[0]) != 0;
        return yes
            ? (args.length > 1 ? args[1] : 1.0)
            : (args.length > 2 ? args[2] : 0.0);
      default:
        throw const _FormulaError('#NAME?');
    }
  }
}

class _Range {
  const _Range(this.from, this.to);
  final (int, int) from;
  final (int, int) to;

  Iterable<Object> values(SheetCalc calc) sync* {
    final r0 = math.min(from.$1, to.$1), r1 = math.max(from.$1, to.$1);
    final c0 = math.min(from.$2, to.$2), c1 = math.max(from.$2, to.$2);
    for (var r = r0; r <= r1; r++) {
      for (var c = c0; c <= c1; c++) {
        yield calc.value(r, c);
      }
    }
  }
}

// ---- What the AI is asked ----

const sheetRule =
    'Write each sheet as a "## " heading (its name) and a Markdown table '
    'under it; the first row of a table is its header. A cell may hold a '
    'formula starting with "=", using cells like B2, ranges like B2:B9 and '
    'SUM, AVERAGE, MIN, MAX, COUNT, ROUND, ABS, IF, with + - * / ^ and & '
    'to join text. Row 1 is the header row, so data starts on row 2. Use '
    'formulas for totals and anything worked out from other cells. Never '
    'put a "|" inside a cell.';

const sheetKinds = [
  'Spreadsheet',
  'Budget',
  'Schedule',
  'Gradebook',
  'Inventory',
  'Tracker',
  'Invoice',
  'Comparison',
];

const sheetSuggestions = [
  'Add a totals row with formulas',
  'Add a column that works out a percentage',
  'Sort the rows by the first column',
  'Fill it with realistic example data',
  'Add 10 more rows of example data',
  'Translate to Spanish',
  'Translate to English',
  'Fix spelling',
];

List<Map<String, String>> generateSheetPrompt({
  required String kind,
  required String about,
  String language = '',
}) => [
  {
    'role': 'system',
    'content':
        'You make spreadsheets. Answer with the spreadsheet only, no '
        'comments before or after it. Start with one line "# Title". '
        '$sheetRule',
  },
  {
    'role': 'user',
    'content': [
      'Make a ${kind.toLowerCase()}.',
      'What it is for: $about',
      if (language.trim().isNotEmpty) 'Write it in ${language.trim()}.',
    ].join('\n'),
  },
];

List<Map<String, String>> sheetEditPrompt({
  required String title,
  required String markdown,
  required String instruction,
}) => [
  {
    'role': 'system',
    'content':
        'You edit spreadsheets. Answer with the whole changed spreadsheet '
        'only (every sheet, even unchanged ones), no comments before or '
        'after it and no title line. Keep formulas as formulas. $sheetRule',
  },
  {
    'role': 'user',
    'content':
        'Spreadsheet "$title":\n\n${markdown.replaceFirst(sheetMarker, '').trim()}'
        '\n\n---\nChange it like this: $instruction',
  },
];
