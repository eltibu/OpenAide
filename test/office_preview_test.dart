import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/studio/office.dart';
import 'package:nexus_assistant/features/studio/office_preview.dart';
import 'package:nexus_assistant/features/studio/slides.dart';
import 'package:nexus_assistant/features/studio/studio_export.dart';

void main() {
  test('Office files open in the preview; others do not', () {
    expect(isOfficeFile('Report.DOCX'), isTrue);
    expect(isOfficeFile('deck.pptx'), isTrue);
    expect(isOfficeFile('book.xlsx'), isTrue);
    expect(isOfficeFile('notes.txt'), isFalse);
    expect(isOfficeFile('docx'), isFalse);
  });

  Future<void> open(WidgetTester tester, String name, List<int> bytes) =>
      tester.pumpWidget(
        MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: OfficePreviewScreen(
            name: name,
            bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
          ),
        ),
      );

  testWidgets('a Word file shows its text, with zoom', (tester) async {
    await open(
      tester,
      'plan.docx',
      toDocx('Plan', '# Goals\n\n- Ship the app\n- Test it'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Ship the app', findRichText: true), findsOne);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(find.text('125%'), findsOne);
    await tester.tap(find.text('125%'));
    await tester.pump();
    expect(find.text('100%'), findsOne);
  });

  testWidgets('slides show one card each, with notes', (tester) async {
    await open(
      tester,
      'deck.pptx',
      toPptx('Deck', [
        Slide(title: 'Hello', body: '- One point', notes: 'Say hi'),
        Slide(title: 'Bye', body: '- Last'),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Slide 1'), findsOne);
    expect(find.text('Slide 2'), findsOne);
    expect(find.textContaining('Say hi', findRichText: true), findsOne);
  });

  testWidgets('a broken file says so', (tester) async {
    await open(tester, 'bad.docx', [1, 2, 3]);
    await tester.pumpAndSettle();
    expect(find.textContaining("can't be shown"), findsOne);
  });
}
