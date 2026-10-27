import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/terminal/file_tools.dart';
import 'package:nexus_assistant/features/terminal/terminal_api.dart';
import 'package:nexus_assistant/features/terminal/terminal_screen.dart';

TerminalEntry _e(String name, {bool dir = false, int size = 0, int day = 1}) =>
    TerminalEntry(
      name: name,
      path: '/h/$name',
      isDir: dir,
      size: size,
      modified: DateTime(2026, 1, day),
    );

class _FakeApi extends TerminalApi {
  _FakeApi()
    : super(
        OpenWebUiClient(baseUrl: 'http://x'),
        const TerminalServer(id: 't', name: 't'),
      );

  final files = <String, String>{
    '/h/a.txt': 'one\ntwo\nthree\n',
    '/h/b.txt': 'one\n2\nthree\nfour\n',
  };
  final deleted = <String>[];

  @override
  Future<({String home, String cwd})> cwd() async => (home: '/h', cwd: '/h');

  @override
  Future<TerminalListing> list(String dir) async => TerminalListing(
    dir: '/h',
    writable: true,
    entries: [
      for (final p in files.keys)
        if (!deleted.contains(p)) _e(p.split('/').last, size: 10),
      _e('.hidden'),
      _e('src', dir: true),
    ],
  );

  @override
  Future<List<int>> read(String path) async => utf8.encode(files[path] ?? '');

  @override
  Future<void> delete(String path) async => deleted.add(path);

  final ran = <int>[];

  @override
  Future<String> startNotebook(String path) async => 'k1';

  @override
  Future<Map<String, dynamic>> runCell(
    String session,
    int index,
    String source,
  ) async {
    ran.add(index);
    return {
      'status': 'ok',
      'execution_count': 7,
      'outputs': [
        {'output_type': 'stream', 'text': 'ran $source'},
      ],
    };
  }

  @override
  Future<void> stopNotebook(String session) async {}
}

void main() {
  test('sorting keeps folders first', () {
    final list = [
      _e('b', size: 5, day: 3),
      _e('a', size: 50, day: 1),
      _e('z', dir: true),
    ];
    expect(sortEntries(list, FileSort.name).map((e) => e.name), [
      'z',
      'a',
      'b',
    ]);
    expect(
      sortEntries(list, FileSort.size, descending: true).map((e) => e.name),
      ['z', 'a', 'b'],
    );
    expect(sortEntries(list, FileSort.modified).map((e) => e.name), [
      'z',
      'a',
      'b',
    ]);
  });

  test('hidden files', () {
    final list = [_e('.env'), _e('a')];
    expect(visibleEntries(list, showHidden: false).map((e) => e.name), ['a']);
    expect(visibleEntries(list, showHidden: true), hasLength(2));
  });

  test('line comparison', () {
    final d = lineDiff('one\ntwo\nthree', 'one\n2\nthree\nfour');
    expect(d.map((l) => '${l.kind}${l.text}').toList(), [
      ' one',
      '-two',
      '+2',
      ' three',
      '+four',
    ]);
    expect(lineDiff('a  b', 'a b', ignoreSpace: true).single.kind, ' ');
  });

  testWidgets('select two files, compare, then delete', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(
      MaterialApp(
        theme: nexusTheme(Brightness.light),
        home: FileBrowser(api: api),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('.hidden'), findsNothing);
    expect(find.text('a.txt'), findsOneWidget);

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('b.txt'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Compare'));
    await tester.pumpAndSettle();
    expect(find.text('2 added · 1 removed'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(api.deleted, ['/h/a.txt', '/h/b.txt']);
    expect(find.text('a.txt'), findsNothing);
  });

  testWidgets('a notebook shows its cells', (tester) async {
    final nb = jsonEncode({
      'cells': [
        {
          'cell_type': 'markdown',
          'source': ['# Title'],
        },
        {
          'cell_type': 'code',
          'execution_count': 1,
          'source': ['print(1)'],
          'outputs': [
            {
              'output_type': 'stream',
              'text': ['1\n'],
            },
          ],
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NotebookView(source: nb)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('In [1]'), findsOneWidget);
    expect(find.text('print(1)'), findsOneWidget);
    expect(find.text('1\n'), findsOneWidget);
  });

  testWidgets('notebook cells run on the server', (tester) async {
    final api = _FakeApi();
    final nb = jsonEncode({
      'cells': [
        {'cell_type': 'markdown', 'source': 'Hi'},
        {'cell_type': 'code', 'source': 'x = 1', 'outputs': []},
        {'cell_type': 'code', 'source': 'print(x)', 'outputs': []},
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotebookView(source: nb, api: api, path: '/h/n.ipynb'),
        ),
      ),
    );
    await tester.tap(find.text('Run all'));
    await tester.pumpAndSettle();
    expect(api.ran, [1, 2]);
    expect(find.text('ran print(x)'), findsOneWidget);
    expect(find.text('In [7]'), findsNWidgets(2));
  });
}
