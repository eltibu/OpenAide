// Runs against a real Open WebUI server with a terminal server (Open
// Terminal) connected; see server_sync_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/terminal/terminal_api.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  late OpenWebUiClient client;
  late TerminalApi api;

  setUp(() async {
    client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final servers = await terminalServers(client);
    if (servers.isEmpty) fail('No terminal server is connected');
    api = TerminalApi(client, servers.first);
  });

  test('browses, writes, uploads, renames and deletes files', () async {
    final home = (await api.cwd()).home;
    final dir = joinPath(
      home,
      'nexus-test-${DateTime.now().millisecondsSinceEpoch}',
    );
    await api.mkdir(dir);
    try {
      await api.write(joinPath(dir, 'a.txt'), 'hello from nexus');
      await api.upload(dir, utf8.encode('uploaded'), 'b.txt');
      var listing = await api.list(dir);
      expect(listing.entries.map((e) => e.name), ['a.txt', 'b.txt']);
      expect(
        utf8.decode(await api.read(joinPath(dir, 'a.txt'))),
        'hello from nexus',
      );

      await api.move(joinPath(dir, 'b.txt'), joinPath(dir, 'c.txt'));
      await api.delete(joinPath(dir, 'a.txt'));
      listing = await api.list(dir);
      expect(listing.entries.map((e) => e.name), ['c.txt']);
      expect(utf8.decode(await api.read(joinPath(dir, 'c.txt'))), 'uploaded');

      final parent = await api.list(home);
      final mine = parent.entries.firstWhere((e) => e.path == dir);
      expect(mine.isDir, isTrue);
    } finally {
      await api.delete(dir);
    }
  }, skip: skip);

  test('runs commands in a shell', () async {
    final id = await api.openShell();
    final ws = await api.connect(id);
    final out = StringBuffer();
    final got = Completer<void>();
    final sub = ws.listen((data) {
      if (data is List<int>) out.write(utf8.decode(data, allowMalformed: true));
      if (out.toString().contains('nexus-ok-42') && !got.isCompleted) {
        got.complete();
      }
    });
    ws.add(utf8.encode('echo nexus-ok-\$((40+2))\n'));
    await got.future.timeout(const Duration(seconds: 10));
    await sub.cancel();
    await ws.close();
    await api.closeShell(id);
  }, skip: skip);
}
