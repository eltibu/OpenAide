import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/studio/office.dart';
import 'package:nexus_assistant/features/studio/office_preview.dart';

const _r =
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';

String _rels(Map<String, String> targets) =>
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '${[for (final e in targets.entries) '<Relationship Id="${e.key}" Type="x" Target="${e.value}"/>'].join()}'
    '</Relationships>';

Uint8List _zip(Map<String, String> files) {
  final a = Archive();
  for (final e in files.entries) {
    a.add(ArchiveFile.bytes(e.key, utf8.encode(e.value)));
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}

final deck = _zip({
  '_rels/.rels': _rels({'rId1': 'ppt/presentation.xml'}),
  'ppt/presentation.xml':
      '<p:presentation xmlns:p="p" $_r><p:sldIdLst>'
      '<p:sldId id="256" r:id="rId1"/><p:sldId id="257" r:id="rId2"/>'
      '</p:sldIdLst></p:presentation>',
  'ppt/_rels/presentation.xml.rels': _rels({
    'rId1': 'slides/slide1.xml',
    'rId2': 'slides/slide2.xml',
    'rId3': 'commentAuthors.xml',
  }),
  'ppt/commentAuthors.xml': '<p:cmAuthorLst xmlns:p="p"><p:cmAuthor id="0" name="Ann"/></p:cmAuthorLst>',
  'ppt/slides/slide1.xml': '<p:sld xmlns:p="p"/>',
  'ppt/slides/slide2.xml': '<p:sld xmlns:p="p"/>',
  'ppt/slides/_rels/slide2.xml.rels': _rels({
    'rId1': '../comments/comment1.xml',
  }),
  'ppt/comments/comment1.xml':
      '<p:cmLst xmlns:p="p"><p:cm authorId="0" dt="2026-10-01T10:00:00" idx="1">'
      '<p:pos x="10" y="10"/><p:text>Bigger title here</p:text></p:cm></p:cmLst>',
});

final doc = _zip({
  '_rels/.rels': _rels({'rId1': 'word/document.xml'}),
  'word/document.xml':
      '<w:document xmlns:w="w"><w:body><w:p>'
      '<w:r><w:t>Before </w:t></w:r><w:commentRangeStart w:id="0"/>'
      '<w:r><w:t>the words</w:t></w:r><w:commentRangeEnd w:id="0"/>'
      '</w:p></w:body></w:document>',
  'word/_rels/document.xml.rels': _rels({
    'rId1': 'comments.xml',
    'rId2': 'commentsExtended.xml',
  }),
  'word/comments.xml':
      '<w:comments xmlns:w="w" xmlns:w14="w14">'
      '<w:comment w:id="0" w:author="Ann" w:date="2026-10-01T10:00:00Z">'
      '<w:p w14:paraId="A1"><w:r><w:t>Check this</w:t></w:r></w:p></w:comment>'
      '<w:comment w:id="1" w:author="Bo">'
      '<w:p w14:paraId="B2"><w:r><w:t>Done</w:t></w:r></w:p></w:comment>'
      '</w:comments>',
  'word/commentsExtended.xml':
      '<w15:commentsEx xmlns:w15="w15">'
      '<w15:commentEx w15:paraId="A1" w15:done="1"/>'
      '<w15:commentEx w15:paraId="B2" w15:paraIdParent="A1"/>'
      '</w15:commentsEx>',
});

final book = _zip({
  '_rels/.rels': _rels({'rId1': 'xl/workbook.xml'}),
  'xl/workbook.xml':
      '<workbook $_r><sheets><sheet name="Costs" sheetId="1" r:id="rId1"/>'
      '</sheets></workbook>',
  'xl/_rels/workbook.xml.rels': _rels({'rId1': 'worksheets/sheet1.xml'}),
  'xl/worksheets/sheet1.xml': '<worksheet/>',
  'xl/worksheets/_rels/sheet1.xml.rels': _rels({'rId1': '../comments1.xml'}),
  'xl/comments1.xml':
      '<comments><authors><author>Cy</author></authors><commentList>'
      '<comment ref="B2" authorId="0"><text><r><t>Too high</t></r></text>'
      '</comment></commentList></comments>',
});

void main() {
  test('PowerPoint comments, with who and which slide', () {
    final c = officeComments('deck.pptx', deck).single;
    expect(c.text, 'Bigger title here');
    expect(c.author, 'Ann');
    expect(c.slide, 2);
  });

  test('Word comments with the words they are on, replies and resolved', () {
    final cs = officeComments('plan.docx', doc);
    expect(cs, hasLength(2));
    expect(cs.first.where, '"the words"');
    expect(cs.first.resolved, isTrue);
    expect(cs.last.reply, isTrue);
    expect(cs.last.author, 'Bo');
  });

  test('Excel notes with their cell', () {
    final c = officeComments('book.xlsx', book).single;
    expect(c.where, 'Costs!B2');
    expect(c.author, 'Cy');
    expect(c.text, 'Too high');
  });

  test('files without comments, or not Office files, have none', () {
    expect(officeComments('x.pptx', Uint8List.fromList([1, 2])), isEmpty);
    expect(officeComments('a.txt', doc), isEmpty);
  });

  testWidgets('the preview shows a slide\'s comments and lists them all', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: nexusTheme(Brightness.light),
        home: OfficePreviewScreen(name: 'deck.pptx', bytes: deck),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Bigger title here'), findsOne);
    await tester.tap(find.byTooltip('Comments'));
    await tester.pumpAndSettle();
    expect(find.text('Bigger title here'), findsNWidgets(2));
  });
}
