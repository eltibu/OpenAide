import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// A piece of text with its looks.
class Run {
  const Run(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.code = false,
  });
  final String text;
  final bool bold;
  final bool italic;
  final bool code;
}

/// A paragraph-level part of a document, ready for Word or PDF.
class Block {
  const Block(this.kind, this.runs, {this.level = 0, this.number});

  /// h1, h2, h3, p, bullet, number, quote, code, rule.
  final String kind;
  final List<Run> runs;

  /// How deep a list item sits (0 at the top).
  final int level;

  /// A numbered item's number.
  final int? number;

  String get text => runs.map((r) => r.text).join();
}

/// Reads Markdown into blocks.
List<Block> markdownBlocks(String markdown) {
  final nodes = md.Document(extensionSet: md.ExtensionSet.gitHubWeb)
      .parseLines(markdown.replaceAll('\r\n', '\n').split('\n'));
  final out = <Block>[];

  List<Run> runs(List<md.Node>? children, {bool b = false, bool i = false}) {
    final list = <Run>[];
    for (final n in children ?? const <md.Node>[]) {
      if (n is md.Text) {
        list.add(Run(_unescape(n.text), bold: b, italic: i));
      } else if (n is md.Element) {
        switch (n.tag) {
          case 'strong':
            list.addAll(runs(n.children, b: true, i: i));
          case 'em':
            list.addAll(runs(n.children, b: b, i: true));
          case 'code':
            list.add(Run(_unescape(n.textContent), code: true));
          case 'br':
            list.add(const Run('\n'));
          case 'img':
            final alt = n.attributes['alt'] ?? '';
            if (alt.isNotEmpty) list.add(Run('[$alt]', italic: true));
          case 'input':
            list.add(Run(n.attributes['checked'] != null ? '[x] ' : '[ ] '));
          default:
            list.addAll(runs(n.children, b: b, i: i));
        }
      }
    }
    return list;
  }

  void walk(List<md.Node> nodes, {int depth = 0, String? quote}) {
    for (final n in nodes) {
      if (n is! md.Element) {
        if (n is md.Text && n.text.trim().isNotEmpty) {
          out.add(Block('p', [Run(_unescape(n.text))]));
        }
        continue;
      }
      switch (n.tag) {
        case 'h1' || 'h2' || 'h3':
          out.add(Block(n.tag, runs(n.children)));
        case 'h4' || 'h5' || 'h6':
          out.add(Block('h3', runs(n.children)));
        case 'p':
          out.add(Block(quote ?? 'p', runs(n.children)));
        case 'blockquote':
          walk(n.children ?? const [], depth: depth, quote: 'quote');
        case 'pre':
          out.add(
            Block('code', [
              Run(_unescape(n.textContent).trimRight(), code: true),
            ]),
          );
        case 'hr':
          out.add(const Block('rule', []));
        case 'ul' || 'ol':
          var number = int.tryParse(n.attributes['start'] ?? '') ?? 1;
          for (final li
              in (n.children ?? const <md.Node>[]).whereType<md.Element>()) {
            // An item's own words, then any list inside it, one level down.
            final inline = <md.Node>[];
            final nested = <md.Element>[];
            for (final c in li.children ?? const <md.Node>[]) {
              if (c is md.Element && (c.tag == 'ul' || c.tag == 'ol')) {
                nested.add(c);
              } else if (c is md.Element && c.tag == 'p') {
                inline.addAll(c.children ?? const []);
              } else {
                inline.add(c);
              }
            }
            out.add(
              Block(
                n.tag == 'ol' ? 'number' : 'bullet',
                runs(inline),
                level: depth,
                number: n.tag == 'ol' ? number++ : null,
              ),
            );
            walk(nested, depth: depth + 1);
          }
        case 'table':
          // Tables become one line per row, cells split by a bar.
          for (final row in _rows(n)) {
            out.add(Block('p', [Run(row.join('  |  '))]));
          }
        default:
          walk(n.children ?? const [], depth: depth, quote: quote);
      }
    }
  }

  walk(nodes);
  return out;
}

List<List<String>> _rows(md.Element table) {
  final rows = <List<String>>[];
  void find(md.Node n) {
    if (n is! md.Element) return;
    if (n.tag == 'tr') {
      rows.add([
        for (final c
            in (n.children ?? const <md.Node>[]).whereType<md.Element>())
          _unescape(c.textContent).trim(),
      ]);
    } else {
      for (final c in n.children ?? const <md.Node>[]) {
        find(c);
      }
    }
  }

  find(table);
  return rows;
}

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");

/// A file name from a title.
String exportName(String title, String ext) {
  final base = title
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '')
      .replaceAll(RegExp(r'\s+'), ' ');
  return '${base.isEmpty ? 'Document' : base}.$ext';
}

// ---- Word ----

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _run(Run r) {
  final props = [
    if (r.bold) '<w:b/>',
    if (r.italic) '<w:i/>',
    if (r.code) '<w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/>',
  ].join();
  final parts = r.text.split('\n');
  final text = [
    for (var i = 0; i < parts.length; i++) ...[
      if (i > 0) '<w:br/>',
      '<w:t xml:space="preserve">${_esc(parts[i])}</w:t>',
    ],
  ].join();
  return '<w:r>${props.isEmpty ? '' : '<w:rPr>$props</w:rPr>'}$text</w:r>';
}

String _paragraph(Block b) {
  final style = switch (b.kind) {
    'h1' => 'Heading1',
    'h2' => 'Heading2',
    'h3' => 'Heading3',
    'quote' => 'Quote',
    'code' => 'Code',
    _ => null,
  };
  final indent = (b.kind == 'bullet' || b.kind == 'number')
      ? '<w:ind w:left="${360 + b.level * 360}" w:hanging="360"/>'
      : '';
  final border = b.kind == 'rule'
      ? '<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="999999"/></w:pBdr>'
      : '';
  final props =
      '${style == null ? '' : '<w:pStyle w:val="$style"/>'}$border$indent';
  final marker = switch (b.kind) {
    'bullet' => [const Run('•\t')],
    'number' => [Run('${b.number}.\t')],
    _ => const <Run>[],
  };
  return '<w:p>${props.isEmpty ? '' : '<w:pPr>$props</w:pPr>'}'
      '${[...marker, ...b.runs].map(_run).join()}</w:p>';
}

const _styles = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault>
<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:b/><w:sz w:val="48"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="280" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="30"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720"/></w:pPr><w:rPr><w:i/><w:color w:val="555555"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/><w:sz w:val="20"/></w:rPr></w:style>
</w:styles>''';

/// The document as a Word file (.docx), which Google Docs opens too.
Uint8List toDocx(String title, String markdown) {
  final body = [
    if (title.trim().isNotEmpty)
      '<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr>${_run(Run(title.trim()))}</w:p>',
    for (final b in markdownBlocks(markdown)) _paragraph(b),
  ].join();
  final document =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>$body<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>'
      '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>'
      '</w:sectPr></w:body></w:document>';
  final files = {
    '[Content_Types].xml':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        '</Types>',
    '_rels/.rels':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>',
    'word/_rels/document.xml.rels':
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>',
    'word/document.xml': document,
    'word/styles.xml': _styles,
  };
  final archive = Archive();
  for (final e in files.entries) {
    final bytes = utf8.encode(e.value);
    archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

// ---- PDF ----

/// Roboto from the app's assets, so PDFs have accents, quotes and bullets.
Future<pw.ThemeData> pdfTheme(Future<ByteData> Function(String) load) async {
  Future<pw.Font> font(String name) async =>
      pw.Font.ttf(await load('assets/fonts/Roboto-$name.ttf'));
  return pw.ThemeData.withFont(
    base: await font('Regular'),
    bold: await font('Bold'),
    italic: await font('Italic'),
    boldItalic: await font('BoldItalic'),
  );
}

/// The document as a PDF.
Future<Uint8List> toPdf(
  String title,
  String markdown, {
  pw.ThemeData? theme,
}) async {
  final doc = pw.Document(title: title, theme: theme);
  pw.TextSpan span(Run r, double size) => pw.TextSpan(
    text: r.text,
    style: pw.TextStyle(
      fontSize: size,
      fontWeight: r.bold ? pw.FontWeight.bold : null,
      fontStyle: r.italic ? pw.FontStyle.italic : null,
      font: r.code ? pw.Font.courier() : null,
    ),
  );
  pw.Widget text(List<Run> runs, double size) => pw.RichText(
    text: pw.TextSpan(children: [for (final r in runs) span(r, size)]),
  );

  final widgets = <pw.Widget>[
    if (title.trim().isNotEmpty)
      pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 14),
        child: pw.Text(
          title.trim(),
          style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
        ),
      ),
    for (final b in markdownBlocks(markdown))
      switch (b.kind) {
        'h1' || 'h2' || 'h3' => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 12, bottom: 4),
          child: text(
            [for (final r in b.runs) Run(r.text, bold: true, italic: r.italic)],
            switch (b.kind) {
              'h1' => 19,
              'h2' => 16,
              _ => 13.5,
            },
          ),
        ),
        'bullet' || 'number' => pw.Padding(
          padding: pw.EdgeInsets.only(left: 14.0 + b.level * 14, bottom: 3),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(
                width: 16,
                child: pw.Text(b.kind == 'bullet' ? '•' : '${b.number}.'),
              ),
              pw.Expanded(child: text(b.runs, 11)),
            ],
          ),
        ),
        'quote' => pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 6),
          padding: const pw.EdgeInsets.only(left: 10),
          decoration: const pw.BoxDecoration(
            border: pw.Border(
              left: pw.BorderSide(color: PdfColors.grey, width: 2),
            ),
          ),
          child: text([
            for (final r in b.runs) Run(r.text, bold: r.bold, italic: true),
          ], 11),
        ),
        'code' => pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 6),
          padding: const pw.EdgeInsets.all(6),
          color: PdfColors.grey200,
          child: text(b.runs, 9.5),
        ),
        'rule' => pw.Divider(color: PdfColors.grey),
        _ => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: text(b.runs, 11),
        ),
      },
  ];
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.letter,
      margin: const pw.EdgeInsets.all(54),
      footer: (c) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          '${c.pageNumber} / ${c.pagesCount}',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey),
        ),
      ),
      build: (_) => widgets,
    ),
  );
  return doc.save();
}
