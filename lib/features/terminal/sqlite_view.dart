/// A SQLite database from the terminal server, read on the phone: its
/// tables a page at a time, or any query, as the web's SQLite viewer does.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

/// Opens [bytes] as a database (a private copy; the server's file is not
/// changed).
Future<Database> openDatabaseCopy(List<int> bytes, String name) async {
  final dir = await Directory.systemTemp.createTemp('nexus-sqlite');
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes, flush: true);
  return sqlite3.open(file.path, mode: OpenMode.readOnly);
}

/// The tables (and views) in [db], by name.
List<String> tablesOf(Database db) => [
  for (final r in db.select(
    "SELECT name FROM sqlite_master WHERE type IN ('table','view') "
    "AND name NOT LIKE 'sqlite_%' ORDER BY name",
  ))
    '${r['name']}',
];

class SqliteView extends StatefulWidget {
  const SqliteView({super.key, required this.bytes, required this.name});
  final List<int> bytes;
  final String name;

  @override
  State<SqliteView> createState() => _SqliteViewState();
}

class _SqliteViewState extends State<SqliteView> {
  static const _pageSize = 50;
  Database? _db;
  List<String> _tables = const [];
  String? _table;
  int _page = 0;
  ResultSet? _rows;
  String? _problem;
  final _query = TextEditingController();
  bool _custom = false;

  @override
  void initState() {
    super.initState();
    _openDb();
  }

  Future<void> _openDb() async {
    try {
      final db = await openDatabaseCopy(widget.bytes, widget.name);
      if (!mounted) {
        db.dispose();
        return;
      }
      _db = db;
      _tables = tablesOf(db);
      if (_tables.isNotEmpty) _show(_tables.first);
      setState(() {});
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    }
  }

  @override
  void dispose() {
    _db?.dispose();
    _query.dispose();
    super.dispose();
  }

  void _show(String table, {int page = 0}) {
    final name = table.replaceAll('"', '""');
    _run(
      'SELECT * FROM "$name" LIMIT $_pageSize OFFSET ${page * _pageSize}',
      table: table,
      page: page,
    );
  }

  void _run(String sql, {String? table, int page = 0}) {
    final db = _db;
    if (db == null) return;
    setState(() {
      _problem = null;
      _custom = table == null;
      _table = table ?? _table;
      _page = page;
      try {
        _rows = db.select(sql);
      } catch (e) {
        _rows = null;
        _problem = '$e';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final scheme = Theme.of(context).colorScheme;
    if (_db == null) {
      return Center(
        child: _problem == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Text("This database can't be opened.\n$_problem"),
              ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _custom ? null : _table,
                  hint: const Text('Table'),
                  items: [
                    for (final t in _tables)
                      DropdownMenuItem(value: t, child: Text(t)),
                  ],
                  onChanged: (t) => t == null ? null : _show(t),
                ),
              ),
              if (!_custom && _table != null) ...[
                IconButton(
                  tooltip: 'Previous page',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _page == 0
                      ? null
                      : () => _show(_table!, page: _page - 1),
                ),
                Text('${_page + 1}'),
                IconButton(
                  tooltip: 'Next page',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: (rows?.length ?? 0) < _pageSize
                      ? null
                      : () => _show(_table!, page: _page + 1),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: TextField(
            controller: _query,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'SELECT … (read only)',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Run',
                icon: const Icon(Icons.play_arrow),
                onPressed: () => _run(_query.text),
              ),
            ),
            onSubmitted: _run,
          ),
        ),
        if (_problem != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_problem!, style: TextStyle(color: scheme.error)),
          ),
        if (rows != null)
          Expanded(
            child: rows.isEmpty
                ? const Center(child: Text('No rows'))
                : SingleChildScrollView(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowHeight: 36,
                        dataRowMinHeight: 32,
                        dataRowMaxHeight: 48,
                        columns: [
                          for (final c in rows.columnNames)
                            DataColumn(label: Text(c)),
                        ],
                        rows: [
                          for (final r in rows.rows)
                            DataRow(
                              cells: [
                                for (final v in r)
                                  DataCell(
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 240,
                                      ),
                                      child: Text(
                                        v == null
                                            ? 'NULL'
                                            : v is List<int>
                                            ? '<${v.length} bytes>'
                                            : '$v',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
      ],
    );
  }
}
