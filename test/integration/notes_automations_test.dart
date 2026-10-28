// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/automations/automations_api.dart';
import 'package:nexus_assistant/features/notes/notes_api.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;
  late OpenWebUiClient client;

  setUp(() async {
    client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
  });

  test('writes, pins and deletes notes', () async {
    final api = NotesApi(client);
    final note = await api.create('nexus note');
    await api.update(note.id, markdown: '# Hello\n\n- one\n- two');
    var got = await api.get(note.id);
    expect(got.markdown, '# Hello\n\n- one\n- two');
    // The web editor shows the HTML when there's no rich-text form.
    final raw = await client.send('GET', '/api/v1/notes/${note.id}') as Map;
    expect(raw['data']['content']['json'], isNull);
    expect(raw['data']['content']['html'], contains('Hello</h1>'));

    await api.togglePin(note.id);
    expect(
      (await api.list()).firstWhere((n) => n.id == note.id).pinned,
      isTrue,
    );
    await api.update(note.id, title: 'renamed');
    got = await api.get(note.id);
    expect(got.title, 'renamed');
    expect(got.markdown, startsWith('# Hello'));
    expect(got.updated.year, DateTime.now().year);

    await api.delete(note.id);
    expect((await api.list()).where((n) => n.id == note.id), isEmpty);
  }, skip: skip);

  test('adds files to a note and keeps them when the text changes', () async {
    final api = NotesApi(client);
    final note = await api.create('nexus files note');
    final up = await client.uploadFile(
      'minutes from Tuesday'.codeUnits,
      'minutes.txt',
      contentType: 'text/plain',
    );
    final item = noteFileItem(up);
    expect(item['name'], 'minutes.txt');
    expect(item['type'], 'file');
    await api.update(note.id, files: [item]);
    await api.update(note.id, markdown: 'see the file');
    var got = await api.get(note.id);
    expect(got.markdown, 'see the file');
    expect(got.files.map((f) => f['id']), [up['id']]);
    await api.update(note.id, files: []);
    got = await api.get(note.id);
    expect(got.files, isEmpty);
    await api.delete(note.id);
  }, skip: skip);

  test('creates, pauses, runs and deletes automations', () async {
    final api = AutomationsApi(client);
    final models =
        ((await client.send('GET', '/api/models')) as Map)['data'] as List;
    final a = await api.save(null, {
      'name': 'nexus auto',
      'data': {
        'prompt': 'Say hi',
        'model_id': models.first['id'],
        'rrule': (Schedule(
          frequency: 'WEEKLY',
          days: ['MO', 'FR'],
          hour: 8,
        )).build(),
        'target': {'type': 'chat'},
      },
      'is_active': true,
    });
    try {
      expect(a.active, isTrue);
      expect(a.nextRun, isNotNull);
      expect(Schedule.parse(a.rrule).days, ['MO', 'FR']);
      expect((await api.list()).any((x) => x.id == a.id), isTrue);

      // A terminal to run commands on comes back as it was saved.
      final withTerminal = await api.save(a.id, {
        'name': a.name,
        'data': {
          ...a.data,
          'terminal': {'server_id': 'box', 'cwd': '/work'},
        },
        'is_active': true,
      });
      expect(withTerminal.data['terminal'], {
        'server_id': 'box',
        'cwd': '/work',
      });

      await api.toggle(a.id);
      expect((await api.get(a.id)).active, isFalse);

      await api.run(a.id);
      List<AutomationRun> runs = const [];
      for (var i = 0; i < 20 && runs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        runs = await api.runs(a.id);
      }
      expect(runs, isNotEmpty);
    } finally {
      await api.delete(a.id);
    }
  }, skip: skip);
}
