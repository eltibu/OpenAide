import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/terminal/terminal_api.dart';
import 'package:nexus_assistant/features/terminal/terminal_screen.dart';

class _FakeApi extends TerminalApi {
  _FakeApi()
    : super(
        OpenWebUiClient(baseUrl: 'http://x'),
        const TerminalServer(id: 't', name: 't'),
      );

  @override
  Future<({String home, String cwd})> cwd() async => (home: '/h', cwd: '/h');

  @override
  Future<TerminalListing> list(String dir) async => TerminalListing(
    dir: dir,
    writable: true,
    entries: dir == '/h'
        ? [
            const TerminalEntry(name: 'src', path: '/h/src', isDir: true),
            const TerminalEntry(
              name: 'notes.txt',
              path: '/h/notes.txt',
              isDir: false,
            ),
          ]
        : [
            const TerminalEntry(
              name: 'main.py',
              path: '/h/src/main.py',
              isDir: false,
            ),
          ],
  );

  @override
  Future<List<int>> read(String path) async => utf8.encode('one\ntwo\nthree');
}

void main() {
  test('a question about picked lines quotes them with where they are', () {
    const text = 'one\ntwo\nthree';
    expect(
      fileAskMessage(
        '/h/a.txt',
        text,
        const TextSelection.collapsed(offset: 0),
        'Why?',
      ),
      'Why?',
    );
    expect(
      fileAskMessage(
        '/h/a.txt',
        text,
        const TextSelection(baseOffset: 4, extentOffset: 13),
        'Shorter',
      ),
      '> /h/a.txt:2-3\n> two\n> three\n\nShorter',
    );
  });

  testWidgets('back and forward, grid view, and asking about a file', (
    tester,
  ) async {
    final asked = <(String, String)>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: nexusTheme(Brightness.light),
        home: FileBrowser(
          api: _FakeApi(),
          onAskFile: (message, bytes, name) async => asked.add((message, name)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    expect(find.text('main.py'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('notes.txt'), findsOneWidget);
    await tester.tap(find.byTooltip('Forward'));
    await tester.pumpAndSettle();
    expect(find.text('main.py'), findsOneWidget);

    await tester.tap(find.byTooltip('Sort and show'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Grid view'));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);

    await tester.tap(find.text('main.py'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Ask or edit…'),
      'Explain',
    );
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(asked, [('Explain', 'main.py')]);
  });
}
