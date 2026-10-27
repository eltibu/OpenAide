/// Excel, PowerPoint and Word files in and out of the Studio.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:xml/xml.dart';

import 'pptx_parts.dart';
import 'sheet.dart';
import 'slides.dart';
import 'studio_doc.dart' show titleAndBody;

// ---- Shared ----

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    // Characters XML can't hold at all.
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

const _xmlHead = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
const _relNs =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _pkgRelNs =
    'http://schemas.openxmlformats.org/package/2006/relationships';

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  for (final e in files.entries) {
    final bytes = utf8.encode(e.value);
    archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _rels(List<(String id, String type, String target)> rels) =>
    '$_xmlHead<Relationships xmlns="$_pkgRelNs">${[for (final (id, type, target) in rels) '<Relationship Id="$id" Type="$_relNs/$type" Target="$target"/>'].join()}</Relationships>';

/// A file that isn't what it says it is.
class OfficeFileError implements Exception {
  const OfficeFileError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The parts of an Office file (a zip of XML).
class _Package {
  _Package(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const OfficeFileError(
        'This file isn\'t a Word, Excel or '
        'PowerPoint file (or it is an old .doc/.xls/.ppt one: save it as '
        '.docx, .xlsx or .pptx first)',
      );
    }
    for (final f in archive.files) {
      if (f.isFile) _files[f.name.replaceAll('\\', '/')] = f.content;
    }
  }

  final _files = <String, List<int>>{};

  bool has(String path) => _files.containsKey(path);

  XmlDocument? xml(String path) {
    final b = _files[path];
    if (b == null) return null;
    try {
      return XmlDocument.parse(utf8.decode(b, allowMalformed: true));
    } catch (_) {
      return null;
    }
  }

  /// A part's relationships: id → the part they point at.
  Map<String, String> rels(String part) {
    final slash = part.lastIndexOf('/');
    final dir = slash < 0 ? '' : part.substring(0, slash);
    final name = part.substring(slash + 1);
    final doc = xml('${dir.isEmpty ? '' : '$dir/'}_rels/$name.rels');
    if (doc == null) return const {};
    return {
      for (final r in _all(doc, 'Relationship'))
        if (r.getAttribute('TargetMode') != 'External')
          '${r.getAttribute('Id')}': _resolve(
            dir,
            '${r.getAttribute('Target')}',
          ),
    };
  }
}

String _resolve(String dir, String target) {
  if (target.startsWith('/')) return target.substring(1);
  final parts = [if (dir.isNotEmpty) ...dir.split('/')];
  for (final p in target.split('/')) {
    if (p == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else if (p != '.' && p.isNotEmpty) {
      parts.add(p);
    }
  }
  return parts.join('/');
}

Iterable<XmlElement> _all(XmlNode n, String local) =>
    n.descendants.whereType<XmlElement>().where((e) => e.localName == local);

Iterable<XmlElement> _kids(XmlNode n, String local) =>
    n.children.whereType<XmlElement>().where((e) => e.localName == local);

XmlElement? _kid(XmlNode n, String local) => _kids(n, local).firstOrNull;

String? _attr(XmlElement e, String local) =>
    e.attributes.where((a) => a.localName == local).firstOrNull?.value;

/// The `r:id` of an element (not its plain `id`).
String? _rid(XmlElement e, [String local = 'id']) => e.attributes
    .where((a) => a.localName == local && a.name.prefix != null)
    .firstOrNull
    ?.value;

// ---- Excel ----

final _plainNumber = RegExp(r'^-?(0|[1-9]\d*)(\.\d+)?$');

/// Excel's own names for what a formula calls.
String _excelFormula(String f) => f
    .replaceAll(';', ',')
    .replaceAllMapped(
      RegExp(r'\bAVG\(', caseSensitive: false),
      (_) => 'AVERAGE(',
    );

String _sheetName(String name, Set<String> taken) {
  var n = name
      .replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (n.isEmpty) n = 'Sheet';
  if (n.length > 31) n = n.substring(0, 31);
  var out = n;
  for (var i = 2; taken.contains(out.toLowerCase()); i++) {
    final tail = ' ($i)';
    out = '${n.substring(0, math.min(n.length, 31 - tail.length))}$tail';
  }
  taken.add(out.toLowerCase());
  return out;
}

const _xlsxStyles =
    '$_xmlHead<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<numFmts count="3">'
    '<numFmt numFmtId="164" formatCode="&quot;\$&quot;#,##0.00"/>'
    '<numFmt numFmtId="165" formatCode="&quot;€&quot;#,##0.00"/>'
    '<numFmt numFmtId="166" formatCode="&quot;£&quot;#,##0.00"/>'
    '</numFmts>'
    '<fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font>'
    '<font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>'
    '<fills count="3"><fill><patternFill patternType="none"/></fill>'
    '<fill><patternFill patternType="gray125"/></fill>'
    '<fill><patternFill patternType="solid"><fgColor rgb="FFEDEDED"/><bgColor indexed="64"/></patternFill></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="9">'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>'
    '<xf numFmtId="9" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="10" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '</cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    '</styleSheet>';

/// The style a typed number keeps in Excel: 45% stays a percentage.
int _numberStyle(String raw) {
  final t = raw.trim();
  final decimals = t.contains('.');
  if (t.endsWith('%')) return decimals ? 3 : 2;
  if (t.startsWith(r'$')) return 6;
  if (t.startsWith('€')) return 7;
  if (t.startsWith('£')) return 8;
  if (t.contains(',')) return decimals ? 5 : 4;
  return 0;
}

String _sheetXml(Sheet s) {
  final calc = SheetCalc(s);
  final rows = StringBuffer();
  final widths = List.filled(s.columnCount, 8.0);
  for (var r = 0; r < s.rows.length; r++) {
    final cells = StringBuffer();
    for (var c = 0; c < s.columnCount; c++) {
      final raw = s.cell(r, c);
      final t = raw.trim();
      if (t.isEmpty) continue;
      final ref = '${columnName(c)}${r + 1}';
      widths[c] = math.max(
        widths[c],
        math.min(60, calc.display(r, c).length * 1.1 + 2),
      );
      final header = r == 0 ? ' s="1"' : '';
      if (t.startsWith('=') && t.length > 1) {
        final v = calc.value(r, c);
        final f = '<f>${_esc(_excelFormula(t.substring(1)))}</f>';
        if (v is double && v.isFinite) {
          cells.write('<c r="$ref"$header>$f<v>$v</v></c>');
        } else if (v is String && v.startsWith('#')) {
          cells.write('<c r="$ref"$header t="e">$f<v>${_esc(v)}</v></c>');
        } else {
          cells.write('<c r="$ref"$header t="str">$f<v>${_esc('$v')}</v></c>');
        }
        continue;
      }
      final n = _plainNumber.hasMatch(t) ? double.parse(t) : parseNumber(t);
      final style = n == null || _plainNumber.hasMatch(t) ? 0 : _numberStyle(t);
      // Numbers with leading zeros (zip codes, ids) stay text.
      if (n != null && !RegExp(r'^-?0\d').hasMatch(t)) {
        final s = style != 0 ? ' s="$style"' : header;
        cells.write('<c r="$ref"$s><v>$n</v></c>');
      } else {
        cells.write(
          '<c r="$ref"$header t="inlineStr"><is><t xml:space="preserve">'
          '${_esc(raw)}</t></is></c>',
        );
      }
    }
    if (cells.isNotEmpty) rows.write('<row r="${r + 1}">$cells</row>');
  }
  final cols = [
    for (var c = 0; c < widths.length; c++)
      '<col min="${c + 1}" max="${c + 1}" width="${widths[c].toStringAsFixed(1)}" customWidth="1"/>',
  ].join();
  return '$_xmlHead<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="$_relNs">'
      '<sheetViews><sheetView workbookViewId="0">'
      '${s.rows.length > 1 ? '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>' : ''}'
      '</sheetView></sheetViews>'
      '<sheetFormatPr defaultRowHeight="15"/>'
      '${cols.isEmpty ? '' : '<cols>$cols</cols>'}'
      '<sheetData>$rows</sheetData></worksheet>';
}

/// The sheets as an Excel file (.xlsx). Formulas stay formulas; Excel
/// works them out again when it opens the file.
Uint8List toXlsx(List<Sheet> sheets) {
  final list = sheets.isEmpty ? [Sheet(name: 'Sheet1')] : sheets;
  final taken = <String>{};
  final names = [for (final s in list) _sheetName(s.name, taken)];
  final n = list.length;
  return _zip({
    '[Content_Types].xml':
        '$_xmlHead<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '${[for (var i = 1; i <= n; i++) '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}'
        '</Types>',
    '_rels/.rels': _rels([('rId1', 'officeDocument', 'xl/workbook.xml')]),
    'xl/workbook.xml':
        '$_xmlHead<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="$_relNs">'
        '<bookViews><workbookView/></bookViews><sheets>'
        '${[for (var i = 0; i < n; i++) '<sheet name="${_esc(names[i])}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}'
        '</sheets><calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>',
    'xl/_rels/workbook.xml.rels': _rels([
      for (var i = 1; i <= n; i++)
        ('rId$i', 'worksheet', 'worksheets/sheet$i.xml'),
      ('rId${n + 1}', 'styles', 'styles.xml'),
    ]),
    'xl/styles.xml': _xlsxStyles,
    for (var i = 0; i < n; i++)
      'xl/worksheets/sheet${i + 1}.xml': _sheetXml(list[i]),
  });
}

/// The text of a shared or inline string (rich text joined up).
String _stringText(XmlElement si) {
  final runs = _kids(si, 'r').toList();
  if (runs.isEmpty) return _kid(si, 't')?.innerText ?? '';
  return runs.map((r) => _kid(r, 't')?.innerText ?? '').join();
}

const _dateFormats = {14, 15, 16, 17, 22};

DateTime _excelDate(double serial) => DateTime.utc(
  1899,
  12,
  30,
).add(Duration(milliseconds: (serial * 86400000).round()));

String _dateText(double serial) {
  final d = _excelDate(serial);
  String two(int n) => n.toString().padLeft(2, '0');
  final day = '${d.year}-${two(d.month)}-${two(d.day)}';
  final hasTime = serial != serial.truncateToDouble();
  return hasTime && serial >= 1
      ? '$day ${two(d.hour)}:${two(d.minute)}'
      : hasTime
      ? '${two(d.hour)}:${two(d.minute)}'
      : day;
}

/// Reads an Excel file (.xlsx): every sheet, with formulas kept where it
/// has them, and numbers, dates and text as Excel shows them.
List<Sheet> sheetsFromXlsx(Uint8List bytes) {
  final pkg = _Package(bytes);
  final root = pkg
      .rels('')
      .entries
      .where((e) => e.value.endsWith('.xml'))
      .map((e) => e.value)
      .where((p) => pkg.xml(p)?.rootElement.localName == 'workbook')
      .firstOrNull;
  final book = root == null ? null : pkg.xml(root);
  if (book == null) throw const OfficeFileError('This isn\'t an Excel file');
  final rels = pkg.rels(root!);
  String? relOf(String type) => rels.values
      .where((p) => pkg.xml(p)?.rootElement.localName == type)
      .firstOrNull;

  final strings = <String>[];
  final sst = relOf('sst');
  if (sst != null) {
    for (final si in _kids(pkg.xml(sst)!.rootElement, 'si')) {
      strings.add(_stringText(si));
    }
  }

  // Which cell styles are dates, and which are percentages.
  final dateStyles = <int>{};
  final percentStyles = <int>{};
  final stylesPart = relOf('styleSheet');
  if (stylesPart != null) {
    final st = pkg.xml(stylesPart)!.rootElement;
    final custom = {
      for (final f in _all(st, 'numFmt'))
        int.tryParse(_attr(f, 'numFmtId') ?? '') ?? -1:
            (_attr(f, 'formatCode') ?? '').toLowerCase(),
    };
    final xfs = _kid(st, 'cellXfs');
    if (xfs != null) {
      for (final (i, xf) in _kids(xfs, 'xf').indexed) {
        final id = int.tryParse(_attr(xf, 'numFmtId') ?? '') ?? 0;
        final code = (custom[id] ?? '').replaceAll(
          RegExp(r'"[^"]*"|\[[^\]]*\]'),
          '',
        );
        if (_dateFormats.contains(id) ||
            (id >= 164 &&
                RegExp(r'[dy]|mm?:|h').hasMatch(code) &&
                !code.contains('0.0'))) {
          dateStyles.add(i);
        }
        if (id == 9 || id == 10 || (id >= 164 && code.contains('%'))) {
          percentStyles.add(i);
        }
      }
    }
  }

  final sheets = <Sheet>[];
  for (final s in _all(book, 'sheet')) {
    final path = rels[_rid(s)];
    final doc = path == null ? null : pkg.xml(path);
    if (doc == null) continue; // A chart sheet, or missing.
    final sheet = Sheet(
      name: _attr(s, 'name') ?? 'Sheet${sheets.length + 1}',
      rows: [],
    );
    var row = 0;
    for (final r in _all(doc, 'row')) {
      row = (int.tryParse(_attr(r, 'r') ?? '') ?? row + 1);
      var col = 0;
      for (final c in _kids(r, 'c')) {
        final ref = RegExp(r'^([A-Z]+)(\d+)$').firstMatch(_attr(c, 'r') ?? '');
        col = ref == null ? col + 1 : columnIndex(ref.group(1)!)! + 1;
        final type = _attr(c, 't') ?? 'n';
        final style = int.tryParse(_attr(c, 's') ?? '') ?? 0;
        final f = _kid(c, 'f')?.innerText.trim() ?? '';
        final v = _kid(c, 'v')?.innerText ?? '';
        String text;
        if (f.isNotEmpty) {
          text = '=$f';
        } else {
          switch (type) {
            case 's':
              final i = int.tryParse(v) ?? -1;
              text = i >= 0 && i < strings.length ? strings[i] : '';
            case 'inlineStr':
              final is_ = _kid(c, 'is');
              text = is_ == null ? '' : _stringText(is_);
            case 'b':
              text = v == '1' ? 'TRUE' : 'FALSE';
            case 'str' || 'e':
              text = v;
            default:
              final n = double.tryParse(v);
              if (n == null) {
                text = v;
              } else if (dateStyles.contains(style)) {
                text = _dateText(n);
              } else if (percentStyles.contains(style)) {
                text = '${formatNumber(n * 100)}%';
              } else {
                text = formatNumber(n);
              }
          }
        }
        if (text.isNotEmpty) sheet.set(row - 1, col - 1, text);
      }
    }
    if (sheet.rows.isEmpty) sheet.set(0, 0, '');
    sheets.add(sheet);
  }
  if (sheets.isEmpty) {
    throw const OfficeFileError('This Excel file has no sheets');
  }
  return sheets;
}

// ---- CSV ----

/// A sheet's values (formulas worked out) as CSV.
String toCsv(Sheet s) {
  final calc = SheetCalc(s);
  String cell(String v) => RegExp(r'[",\n\r]').hasMatch(v) || v != v.trim()
      ? '"${v.replaceAll('"', '""')}"'
      : v;
  return [
    for (var r = 0; r < s.rows.length; r++)
      [for (var c = 0; c < s.columnCount; c++) cell(calc.display(r, c))]
          .join(','),
  ].join('\r\n');
}

/// Reads CSV (commas, semicolons or tabs, whichever the file uses).
Sheet sheetFromCsv(String text, {String name = 'Sheet1'}) {
  final t = text.startsWith('﻿') ? text.substring(1) : text;
  final firstLine = t.split('\n').first;
  final sep = [',', ';', '\t'].reduce(
    (a, b) =>
        b.allMatches(firstLine).length > a.allMatches(firstLine).length ? b : a,
  );
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < t.length; i++) {
    final ch = t[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < t.length && t[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"' && cell.isEmpty) {
      quoted = true;
    } else if (ch == sep) {
      row.add(cell.toString());
      cell.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < t.length && t[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = [];
    } else {
      cell.write(ch);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  final width = rows.fold(1, (a, r) => math.max(a, r.length));
  final sheet = Sheet(
    name: name,
    rows: [
      for (final r in rows) [...r, ...List.filled(width - r.length, '')],
    ],
  );
  if (sheet.rows.isEmpty) sheet.set(0, 0, '');
  return sheet;
}

// ---- PowerPoint ----

const _slideW = 12192000;
const _slideH = 6858000;

const _pNs =
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:r="$_relNs" '
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"';

String _runsXml(String text, {bool bold = false}) {
  // **bold** stays bold; other marks are taken off.
  final out = StringBuffer();
  final parts = text.split('**');
  for (var i = 0; i < parts.length; i++) {
    final t = plainText(parts[i], trim: false);
    if (t.isEmpty) continue;
    out.write(
      '<a:r><a:rPr lang="en-US"${bold || i.isOdd ? ' b="1"' : ''} dirty="0"/>'
      '<a:t>${_esc(t)}</a:t></a:r>',
    );
  }
  return out.toString();
}

String _paragraphs(List<Point> points, {bool plain = false}) {
  if (points.isEmpty) {
    return '<a:p><a:endParaRPr lang="en-US" dirty="0"/></a:p>';
  }
  return [
    for (final p in points)
      '<a:p>${p.level > 0
          ? '<a:pPr lvl="${p.level}"/>'
          : !p.bullet && !plain
          ? '<a:pPr marL="0" indent="0"><a:buNone/></a:pPr>'
          : ''}${_runsXml(p.text)}</a:p>',
  ].join();
}

String _shape(int id, String name, String ph, String body) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="$name"/>'
    '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr>$ph</p:nvPr></p:nvSpPr>'
    '<p:spPr/><p:txBody><a:bodyPr><a:normAutofit/></a:bodyPr><a:lstStyle/>$body</p:txBody></p:sp>';

String _slideXml(Slide s, bool first) {
  final title = '<a:p>${_runsXml(s.title)}</a:p>';
  final shapes = first
      ? _shape(2, 'Title 1', '<p:ph type="ctrTitle"/>', title) +
            // No subtitle box when there is no subtitle.
            (s.body.trim().isEmpty
                ? ''
                : _shape(
                    3,
                    'Subtitle 2',
                    '<p:ph type="subTitle" idx="1"/>',
                    _paragraphs(slidePoints(s.body), plain: true),
                  ))
      : _shape(2, 'Title 1', '<p:ph type="title"/>', title) +
            _shape(
              3,
              'Content Placeholder 2',
              '<p:ph idx="1"/>',
              _paragraphs(slidePoints(s.body)),
            );
  return '$_xmlHead<p:sld $_pNs><p:cSld><p:spTree>'
      '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>'
      '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
      '$shapes</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>';
}

String _notesXml(Slide s) =>
    '$_xmlHead<p:notes $_pNs><p:cSld><p:spTree>'
    '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
    '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>'
    '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
    '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/>'
    '<p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr>'
    '<p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr><p:spPr/></p:sp>'
    '${_shape(3, 'Notes Placeholder 2', '<p:ph type="body" idx="1"/>', [for (final line in s.notes.trim().split('\n')) '<a:p>${_runsXml(line)}</a:p>'].join())}'
    '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>';

/// The slides as a PowerPoint file (.pptx), widescreen, with speaker
/// notes. The first slide is the title slide.
Uint8List toPptx(String title, List<Slide> slides) {
  final list = slides.isEmpty ? [Slide(title: title)] : slides;
  final n = list.length;
  final hasNotes = [for (final s in list) s.notes.trim().isNotEmpty];
  final anyNotes = hasNotes.contains(true);
  const ct = 'application/vnd.openxmlformats-officedocument.presentationml';
  // presentation.xml.rels: master, then slides, then the rest.
  final notesMasterRel = 'rId${n + 2}';
  final files = <String, String>{
    '[Content_Types].xml':
        '$_xmlHead<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/ppt/presentation.xml" ContentType="$ct.presentation.main+xml"/>'
        '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="$ct.slideMaster+xml"/>'
        '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="$ct.slideLayout+xml"/>'
        '<Override PartName="/ppt/slideLayouts/slideLayout2.xml" ContentType="$ct.slideLayout+xml"/>'
        '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>'
        '${anyNotes ? '<Override PartName="/ppt/notesMasters/notesMaster1.xml" ContentType="$ct.notesMaster+xml"/>'
                  '<Override PartName="/ppt/theme/theme2.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>' : ''}'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '${[for (var i = 1; i <= n; i++) '<Override PartName="/ppt/slides/slide$i.xml" ContentType="$ct.slide+xml"/>'].join()}'
        '${[for (var i = 1; i <= n; i++)
          if (hasNotes[i - 1]) '<Override PartName="/ppt/notesSlides/notesSlide$i.xml" ContentType="$ct.notesSlide+xml"/>'].join()}'
        '</Types>',
    '_rels/.rels':
        '$_xmlHead<Relationships xmlns="$_pkgRelNs">'
        '<Relationship Id="rId1" Type="$_relNs/officeDocument" Target="ppt/presentation.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '</Relationships>',
    'docProps/core.xml':
        '$_xmlHead<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>${_esc(title)}</dc:title></cp:coreProperties>',
    'ppt/presentation.xml':
        '$_xmlHead<p:presentation $_pNs saveSubsetFonts="1">'
        '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
        '${anyNotes ? '<p:notesMasterIdLst><p:notesMasterId r:id="$notesMasterRel"/></p:notesMasterIdLst>' : ''}'
        '<p:sldIdLst>${[for (var i = 1; i <= n; i++) '<p:sldId id="${255 + i}" r:id="rId${i + 1}"/>'].join()}</p:sldIdLst>'
        '<p:sldSz cx="$_slideW" cy="$_slideH"/><p:notesSz cx="6858000" cy="9144000"/>'
        '$pptxTextStyles</p:presentation>',
    'ppt/_rels/presentation.xml.rels': _rels([
      ('rId1', 'slideMaster', 'slideMasters/slideMaster1.xml'),
      for (var i = 1; i <= n; i++)
        ('rId${i + 1}', 'slide', 'slides/slide$i.xml'),
      if (anyNotes)
        (notesMasterRel, 'notesMaster', 'notesMasters/notesMaster1.xml'),
      ('rId${n + 3}', 'theme', 'theme/theme1.xml'),
    ]),
    'ppt/slideMasters/slideMaster1.xml': '$_xmlHead$pptxMaster',
    'ppt/slideMasters/_rels/slideMaster1.xml.rels': _rels([
      ('rId1', 'slideLayout', '../slideLayouts/slideLayout1.xml'),
      ('rId2', 'slideLayout', '../slideLayouts/slideLayout2.xml'),
      ('rId3', 'theme', '../theme/theme1.xml'),
    ]),
    'ppt/slideLayouts/slideLayout1.xml': '$_xmlHead$pptxTitleLayout',
    'ppt/slideLayouts/slideLayout2.xml': '$_xmlHead$pptxContentLayout',
    'ppt/slideLayouts/_rels/slideLayout1.xml.rels': _rels([
      ('rId1', 'slideMaster', '../slideMasters/slideMaster1.xml'),
    ]),
    'ppt/slideLayouts/_rels/slideLayout2.xml.rels': _rels([
      ('rId1', 'slideMaster', '../slideMasters/slideMaster1.xml'),
    ]),
    'ppt/theme/theme1.xml': '$_xmlHead$pptxTheme',
    if (anyNotes) ...{
      'ppt/notesMasters/notesMaster1.xml': '$_xmlHead$pptxNotesMaster',
      'ppt/notesMasters/_rels/notesMaster1.xml.rels': _rels([
        ('rId1', 'theme', '../theme/theme2.xml'),
      ]),
      'ppt/theme/theme2.xml': '$_xmlHead$pptxNotesTheme',
    },
    for (var i = 1; i <= n; i++) ...{
      'ppt/slides/slide$i.xml': _slideXml(list[i - 1], i == 1),
      'ppt/slides/_rels/slide$i.xml.rels': _rels([
        (
          'rId1',
          'slideLayout',
          '../slideLayouts/slideLayout${i == 1 ? 1 : 2}.xml',
        ),
        if (hasNotes[i - 1])
          ('rId2', 'notesSlide', '../notesSlides/notesSlide$i.xml'),
      ]),
      if (hasNotes[i - 1]) ...{
        'ppt/notesSlides/notesSlide$i.xml': _notesXml(list[i - 1]),
        'ppt/notesSlides/_rels/notesSlide$i.xml.rels': _rels([
          ('rId1', 'notesMaster', '../notesMasters/notesMaster1.xml'),
          ('rId2', 'slide', '../slides/slide$i.xml'),
        ]),
      },
    },
  };
  return _zip(files);
}

/// A text body's paragraphs as Markdown lines; list items keep their
/// level.
List<String> _bodyLines(XmlElement txBody, {bool bullets = true}) => [
  for (final p in _kids(txBody, 'p'))
    if (_paragraphText(p).trim().isNotEmpty)
      () {
        final lvl = int.tryParse(_attr(_kid(p, 'pPr') ?? p, 'lvl') ?? '') ?? 0;
        final none = _kid(p, 'pPr')?.let((pr) => _kid(pr, 'buNone')) != null;
        final text = _paragraphText(p).trim();
        return bullets && !none ? '${'  ' * lvl}- $text' : text;
      }(),
];

String _paragraphText(XmlElement p) => [
  for (final e in p.children.whereType<XmlElement>())
    switch (e.localName) {
      'r' || 'fld' =>
        (_kid(e, 'rPr')?.let((pr) => _attr(pr, 'b')) == '1' &&
                (_kid(e, 't')?.innerText.trim().isNotEmpty ?? false))
            ? '**${_kid(e, 't')!.innerText.trim()}**'
            : _kid(e, 't')?.innerText ?? '',
      'br' => ' ',
      _ => '',
    },
].join().replaceAll('****', '');

extension<T extends Object> on T {
  R let<R>(R Function(T) f) => f(this);
}

String _tableMarkdown(XmlElement tbl) {
  final rows = [
    for (final tr in _all(tbl, 'tr'))
      [
        for (final tc in _kids(tr, 'tc'))
          [for (final p in _all(tc, 'p')) _paragraphText(p).trim()]
              .where((t) => t.isNotEmpty)
              .join(' ')
              .replaceAll('|', r'\|'),
      ],
  ];
  if (rows.isEmpty) return '';
  final width = rows.fold(0, (a, r) => math.max(a, r.length));
  String line(List<String> r) =>
      '| ${[for (var c = 0; c < width; c++) c < r.length ? r[c] : ''].join(' | ')} |';
  return [
    line(rows.first),
    '|${List.filled(width, '---').join('|')}|',
    ...rows.skip(1).map(line),
  ].join('\n');
}

/// Reads a PowerPoint file (.pptx): each slide's title, its text as
/// points (tables as tables), and its speaker notes.
List<Slide> slidesFromPptx(Uint8List bytes) {
  final pkg = _Package(bytes);
  final main = pkg
      .rels('')
      .values
      .where((p) => pkg.xml(p)?.rootElement.localName == 'presentation')
      .firstOrNull;
  if (main == null) {
    throw const OfficeFileError('This isn\'t a PowerPoint file');
  }
  final rels = pkg.rels(main);
  final slides = <Slide>[];
  for (final id in _all(pkg.xml(main)!, 'sldId')) {
    final path = rels[_rid(id)];
    final doc = path == null ? null : pkg.xml(path);
    if (doc == null) continue;
    final slide = Slide();
    final body = <String>[];
    final tree = _all(doc, 'spTree').firstOrNull;
    // Shapes in the order they are on the slide, groups included.
    final shapes = tree == null
        ? const <XmlElement>[]
        : tree.descendants.whereType<XmlElement>().where(
            (e) => e.localName == 'sp' || e.localName == 'graphicFrame',
          );
    for (final sp in shapes) {
      if (sp.localName == 'graphicFrame') {
        final tbl = _all(sp, 'tbl').firstOrNull;
        if (tbl != null) body.add(_tableMarkdown(tbl));
        continue;
      }
      final tx = _kid(sp, 'txBody');
      if (tx == null) continue;
      final ph = _all(sp, 'ph').firstOrNull;
      final type = ph == null ? null : _attr(ph, 'type');
      if ((type == 'title' || type == 'ctrTitle') && slide.title.isEmpty) {
        slide.title = _bodyLines(
          tx,
          bullets: false,
        ).join(' ').replaceAll('**', '');
      } else if (type == 'sldNum' || type == 'dt' || type == 'ftr') {
        continue;
      } else {
        // Placeholders for points are lists; text boxes and subtitles
        // are plain lines.
        final lines = _bodyLines(tx, bullets: ph != null && type != 'subTitle');
        if (lines.isNotEmpty) body.add(lines.join('\n'));
      }
    }
    slide.body = body.join('\n\n');
    final notesPath = pkg
        .rels(path!)
        .values
        .where((p) => p.contains('notesSlide'))
        .firstOrNull;
    final notes = notesPath == null ? null : pkg.xml(notesPath);
    if (notes != null) {
      for (final sp in _all(notes, 'sp')) {
        final ph = _all(sp, 'ph').firstOrNull;
        final tx = _kid(sp, 'txBody');
        if (ph != null && _attr(ph, 'type') == 'body' && tx != null) {
          slide.notes = _bodyLines(tx, bullets: false).join('\n');
        }
      }
    }
    slides.add(slide);
  }
  if (slides.isEmpty) {
    throw const OfficeFileError('This presentation has no slides');
  }
  return slides;
}

// ---- Word ----

/// Reads a Word file (.docx) into Markdown: headings, lists, bold and
/// italic, tables. The title is its Title paragraph, if it has one.
(String title, String markdown) markdownFromDocx(Uint8List bytes) {
  final pkg = _Package(bytes);
  final main = pkg
      .rels('')
      .values
      .where((p) => pkg.xml(p)?.rootElement.localName == 'document')
      .firstOrNull;
  final doc = main == null ? null : pkg.xml(main);
  if (doc == null) throw const OfficeFileError('This isn\'t a Word file');
  final rels = pkg.rels(main!);

  // Style ids to what they are (ids are often translated: "Titre1").
  final styleKinds = <String, String>{};
  final stylesPath = rels.values
      .where((p) => pkg.xml(p)?.rootElement.localName == 'styles')
      .firstOrNull;
  if (stylesPath != null) {
    for (final s in _all(pkg.xml(stylesPath)!, 'style')) {
      final id = _attr(s, 'styleId') ?? '';
      final name = (_kid(s, 'name')?.let((n) => _attr(n, 'val')) ?? '')
          .toLowerCase();
      final outline = _all(
        s,
        'outlineLvl',
      ).firstOrNull?.let((o) => _attr(o, 'val'));
      final m = RegExp(r'^heading (\d)$').firstMatch(name);
      if (name == 'title') {
        styleKinds[id] = 'title';
      } else if (m != null) {
        styleKinds[id] = 'h${m.group(1)}';
      } else if (outline != null && int.tryParse(outline) != null) {
        styleKinds[id] = 'h${int.parse(outline) + 1}';
      } else if (name.contains('quote')) {
        styleKinds[id] = 'quote';
      }
    }
  }

  // Which lists are numbered.
  final numbered = <String, Set<int>>{};
  final numberingPath = rels.values
      .where((p) => pkg.xml(p)?.rootElement.localName == 'numbering')
      .firstOrNull;
  if (numberingPath != null) {
    final nd = pkg.xml(numberingPath)!;
    final abstracts = <String, Set<int>>{};
    for (final a in _all(nd, 'abstractNum')) {
      abstracts['${_attr(a, 'abstractNumId')}'] = {
        for (final l in _kids(a, 'lvl'))
          if (!{
            'bullet',
            'none',
          }.contains(_kid(l, 'numFmt')?.let((f) => _attr(f, 'val'))))
            int.tryParse(_attr(l, 'ilvl') ?? '') ?? 0,
      };
    }
    for (final n in _all(nd, 'num')) {
      final a = _kid(n, 'abstractNumId')?.let((x) => _attr(x, 'val'));
      numbered['${_attr(n, 'numId')}'] = abstracts[a] ?? const {};
    }
  }

  String runsText(XmlElement p) {
    final out = StringBuffer();
    for (final r in p.descendants.whereType<XmlElement>().where(
      (e) => e.localName == 'r',
    )) {
      // Text in a nested paragraph (a text box) is read on its own.
      final owner = r.ancestors.whereType<XmlElement>().firstWhere(
        (a) => a.localName == 'p',
      );
      if (owner != p) continue;
      final pr = _kid(r, 'rPr');
      bool on(String tag) {
        final e = pr == null ? null : _kid(pr, tag);
        return e != null && !{'0', 'false'}.contains(_attr(e, 'val'));
      }

      final text = StringBuffer();
      for (final c in r.children.whereType<XmlElement>()) {
        switch (c.localName) {
          case 't':
            text.write(c.innerText);
          case 'tab':
            text.write(' ');
          case 'br' || 'cr':
            text.write('  \n');
        }
      }
      var t = text.toString();
      if (t.trim().isEmpty) {
        out.write(t);
        continue;
      }
      final lead = t.substring(0, t.length - t.trimLeft().length);
      final trail = t.substring(t.trimRight().length);
      t = t.trim();
      if (on('b')) t = '**$t**';
      if (on('i')) t = '*$t*';
      out.write('$lead$t$trail');
    }
    return out.toString().replaceAll('****', '');
  }

  var title = '';
  final blocks = <String>[];
  var lastWasItem = false;
  final body = _all(doc, 'body').firstOrNull;
  if (body == null) return ('', '');
  for (final e in body.children.whereType<XmlElement>()) {
    if (e.localName == 'tbl') {
      blocks.add(_tableMarkdown(e));
      lastWasItem = false;
      continue;
    }
    if (e.localName != 'p') continue;
    final text = runsText(e).trim();
    final pr = _kid(e, 'pPr');
    final styleId = pr == null
        ? null
        : _kid(pr, 'pStyle')?.let((s) => _attr(s, 'val'));
    final kind = styleKinds[styleId] ?? '';
    final num = pr == null ? null : _kid(pr, 'numPr');
    if (text.isEmpty) {
      continue;
    }
    if (kind == 'title' && title.isEmpty && blocks.isEmpty) {
      title = text.replaceAll('*', '');
      continue;
    }
    if (kind.startsWith('h')) {
      final level = (int.tryParse(kind.substring(1)) ?? 1).clamp(1, 3);
      blocks.add('${'#' * level} ${text.replaceAll('**', '')}');
      lastWasItem = false;
    } else if (num != null) {
      final ilvl =
          int.tryParse(_kid(num, 'ilvl')?.let((x) => _attr(x, 'val')) ?? '') ??
          0;
      final numId = _kid(num, 'numId')?.let((x) => _attr(x, 'val'));
      final isNumbered = numbered[numId]?.contains(ilvl) ?? false;
      final item = '${'   ' * ilvl}${isNumbered ? '1.' : '-'} $text';
      if (lastWasItem) {
        blocks[blocks.length - 1] = '${blocks.last}\n$item';
      } else {
        blocks.add(item);
      }
      lastWasItem = true;
    } else {
      blocks.add(kind == 'quote' ? '> $text' : text);
      lastWasItem = false;
    }
  }
  return (title, blocks.join('\n\n'));
}

// ---- Slides as PDF ----

/// The slides as a PDF, one widescreen page each.
Future<Uint8List> slidesToPdf(
  String title,
  List<Slide> slides, {
  pw.ThemeData? theme,
}) async {
  final doc = pw.Document(title: title, theme: theme);
  const format = PdfPageFormat(960, 540);
  for (final (i, s) in slides.indexed) {
    final points = slidePoints(s.body);
    doc.addPage(
      pw.Page(
        pageFormat: format,
        margin: const pw.EdgeInsets.fromLTRB(64, 48, 64, 40),
        build: (_) => i == 0
            ? pw.Column(
                mainAxisAlignment: pw.MainAxisAlignment.center,
                children: [
                  pw.Text(
                    plainText(s.title),
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(
                      fontSize: 44,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 18),
                  for (final p in points)
                    pw.Text(
                      plainText(p.text),
                      textAlign: pw.TextAlign.center,
                      style: const pw.TextStyle(
                        fontSize: 22,
                        color: PdfColors.grey700,
                      ),
                    ),
                ],
              )
            : pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    plainText(s.title),
                    style: pw.TextStyle(
                      fontSize: 34,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 22),
                  for (final p in points)
                    pw.Padding(
                      padding: pw.EdgeInsets.only(
                        left: p.level * 28.0,
                        bottom: 10,
                      ),
                      child: pw.Row(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          if (p.bullet)
                            pw.SizedBox(
                              width: 22,
                              child: pw.Text(
                                p.level == 0 ? '•' : '–',
                                style: const pw.TextStyle(fontSize: 22),
                              ),
                            ),
                          pw.Expanded(
                            child: pw.Text(
                              plainText(p.text),
                              style: pw.TextStyle(
                                fontSize: p.level == 0 ? 22 : 19,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  pw.Spacer(),
                  pw.Align(
                    alignment: pw.Alignment.bottomRight,
                    child: pw.Text(
                      '${i + 1}',
                      style: const pw.TextStyle(
                        fontSize: 12,
                        color: PdfColors.grey,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
  return doc.save();
}

// ---- Opening a file ----

/// A file from the phone as a Studio file: its title and its text.
(String title, String markdown) importFile(String name, Uint8List bytes) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  final base = dot < 0 ? name : name.substring(0, dot);
  switch (ext) {
    case 'docx' || 'docm':
      final (title, md) = markdownFromDocx(bytes);
      return (title.isEmpty ? base : title, md);
    case 'xlsx' || 'xlsm':
      return (base, sheetsToMarkdown(sheetsFromXlsx(bytes)));
    case 'pptx' || 'pptm':
      return (base, slidesToMarkdown(slidesFromPptx(bytes)));
    case 'csv' || 'tsv':
      return (
        base,
        sheetsToMarkdown([
          sheetFromCsv(utf8.decode(bytes, allowMalformed: true), name: base),
        ]),
      );
    case 'md' || 'markdown' || 'txt':
      final (title, md) = titleAndBody(
        utf8.decode(bytes, allowMalformed: true),
      );
      return (title.isEmpty ? base : title, md);
    case 'doc' || 'xls' || 'ppt':
      throw OfficeFileError(
        'Old .$ext files can\'t be opened. Save it as .${ext}x first '
        '(in Office: Save as).',
      );
    default:
      throw const OfficeFileError(
        'The Studio opens Word (.docx), Excel (.xlsx), PowerPoint (.pptx), '
        'CSV and text files.',
      );
  }
}
