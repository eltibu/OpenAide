import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/terminal/sqlite_view.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

void main() {
  test('reads a database copy and its tables', () async {
    final dir = await Directory.systemTemp.createTemp();
    final path = '${dir.path}/t.db';
    sqlite3.open(path)
      ..execute('CREATE TABLE people (id INTEGER, name TEXT)')
      ..execute("INSERT INTO people VALUES (1, 'Ana'), (2, 'Joel')")
      ..dispose();
    final db = await openDatabaseCopy(await File(path).readAsBytes(), 't.db');
    expect(tablesOf(db), ['people']);
    expect(
      db.select('SELECT name FROM people ORDER BY id').last['name'],
      'Joel',
    );
    expect(() => db.execute('DELETE FROM people'), throwsA(anything));
    db.dispose();
  });

  testWidgets('shows the first table', (tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp();
      final path = '${dir.path}/t.db';
      sqlite3.open(path)
        ..execute('CREATE TABLE notes (title TEXT)')
        ..execute("INSERT INTO notes VALUES ('hello')")
        ..dispose();
      final bytes = await File(path).readAsBytes();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SqliteView(bytes: bytes, name: 't.db'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('title'), findsOneWidget);
  });
}
