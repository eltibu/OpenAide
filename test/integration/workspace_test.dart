// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/workspace/knowledge_api.dart';
import 'package:nexus_assistant/features/workspace/models_api.dart';
import 'package:nexus_assistant/features/workspace/prompts_api.dart';

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

  test('prompts', () async {
    final api = PromptsApi(client);
    await api.save(null, command: 'nexus-p', name: 'Nexus', content: 'Hi');
    var p = (await api.list()).firstWhere((p) => p.command == 'nexus-p');
    expect(p.active, isTrue);
    await api.save(p.id, command: 'nexus-p', name: 'Nexus 2', content: 'Yo');
    await api.toggle(p.id);
    p = (await api.list()).firstWhere((p) => p.command == 'nexus-p');
    expect(p.name, 'Nexus 2');
    expect(p.content, 'Yo');
    expect(p.active, isFalse);
    await api.delete(p.id);
    expect((await api.list()).where((x) => x.id == p.id), isEmpty);
  }, skip: skip);

  test('knowledge', () async {
    final api = KnowledgeApi(client);
    final k = await api.create('nexus kb', 'test');
    try {
      await api.update(k.id, 'nexus kb 2', 'test 2');
      expect(
        (await api.list()).firstWhere((x) => x.id == k.id).name,
        'nexus kb 2',
      );
      await api.addFile(k.id, utf8.encode('The sky is green.'), 'a.txt');
      var l = await api.files(k.id);
      expect(l.files.single.name, 'a.txt');
      await api.removeFile(k.id, l.files.single.id);
      l = await api.files(k.id);
      expect(l.files, isEmpty);
      await api.addText(k.id, 'Notes', 'Typed straight in.');
      l = await api.files(k.id);
      expect(l.files.single.name, 'Notes.txt');
    } finally {
      await api.delete(k.id);
    }
  }, skip: skip);

  test('models keep what the app does not show', () async {
    final api = ModelsApi(client);
    final base =
        (((await client.send('GET', '/api/models')) as Map)['data'] as List)
            .first['id'];
    await api.save({
      'id': 'nexus-test-model',
      'name': 'Nexus test',
      'base_model_id': base,
      'meta': {
        'description': 'd',
        'capabilities': {'vision': true},
        'suggestion_prompts': [
          {'content': 'keep me'},
        ],
      },
      'params': {'system': 'Be brief', 'temperature': 0.3},
    }, create: true);
    try {
      var m = await api.get('nexus-test-model');
      expect(m.system, 'Be brief');
      await api.save({
        ...m.json,
        'name': 'Nexus test 2',
        'meta': {
          ...m.meta,
          'toolIds': ['clock'],
        },
      }, create: false);
      m = await api.get('nexus-test-model');
      expect(m.name, 'Nexus test 2');
      expect(m.ids('toolIds'), ['clock']);
      expect(m.params['temperature'], 0.3);
      expect(m.meta['suggestion_prompts'], isNotEmpty);
      await api.toggle(m.id);
      expect((await api.get(m.id)).active, isFalse);
      expect((await api.list()).any((x) => x.id == m.id), isTrue);

      // The Actions menu: only what isn't already so is changed.
      final mine = [m = await api.get(m.id)];
      expect(await api.setAll(mine, hidden: true, active: true), 2);
      m = await api.get(m.id);
      expect(m.meta['hidden'], isTrue);
      expect(m.active, isTrue);
      expect(await api.setAll([m], hidden: true, active: true), 0);
      await api.setAll([m], hidden: false);
      expect((await api.get(m.id)).meta['hidden'], isFalse);
    } finally {
      await api.delete('nexus-test-model');
    }
  }, skip: skip);

  test('tool settings and skills', () async {
    final spec = await client.send(
      'GET',
      '/api/v1/tools/id/clock/valves/user/spec',
    );
    expect(spec == null || spec is Map, isTrue);
    final skill =
        ((await client.send('GET', '/api/v1/skills/')) as List).first as Map;
    final id = skill['id'];
    final before = (await client.send('GET', '/api/v1/skills/id/$id')) as Map;
    await client.send(
      'POST',
      '/api/v1/skills/id/$id/update',
      body: {
        'id': id,
        'name': before['name'],
        'description': 'changed by nexus',
        'content': before['content'],
        'meta': before['meta'] ?? {},
        'is_active': before['is_active'] ?? true,
      },
    );
    final after = (await client.send('GET', '/api/v1/skills/id/$id')) as Map;
    expect(after['description'], 'changed by nexus');
    expect(after['data'], before['data']);
  }, skip: skip);
}
