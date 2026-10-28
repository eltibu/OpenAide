// Runs against a real Open WebUI server as an admin; see
// server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/admin/banners_screen.dart';
import 'package:nexus_assistant/features/admin/config_editor.dart';
import 'package:nexus_assistant/features/admin/connections_screen.dart';
import 'package:nexus_assistant/features/admin/groups_screen.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('every settings page reads and saves its settings', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    for (final s in adminConfigSections) {
      final all = (await client.send('GET', s.read) as Map)
          .cast<String, dynamic>();
      var part = all;
      for (final k in s.path) {
        part = (part[k] as Map).cast<String, dynamic>();
      }
      expect(part, isNotEmpty, reason: s.title);
      for (final k in s.engines.keys) {
        if (s.path.isEmpty || part.containsKey(k)) {
          expect(part.containsKey(k), isTrue, reason: '${s.title} $k');
        }
      }
      try {
        await client.send(
          'POST',
          s.save,
          body: s.toSave?.call(all) ?? ({...all}..remove('status')),
        );
      } on ApiException catch (e) {
        // An unset LDAP server can't be saved until it is filled in.
        if (!(s.title == 'LDAP server' && e.statusCode == 400)) rethrow;
      }
    }

    expect(
      (await client.send('GET', '/api/v1/auths/admin/config/ldap')
          as Map)['ENABLE_LDAP'],
      isFalse,
    );

    // The download buttons get files.
    final db = await client.getBytes('/api/v1/utils/db/download');
    expect(String.fromCharCodes(db.take(15)), 'SQLite format 3');
    final exported = await client.getBytes('/api/v1/configs/export');
    expect(exported, isNotEmpty);
    expect(await client.send('POST', '/api/v1/knowledge/reindex'), isTrue);

    // Banners save and come back.
    final banner = {...newBanner(), 'content': 'Maintenance tonight'};
    await client.send(
      'POST',
      '/api/v1/configs/banners',
      body: {
        'banners': [banner],
      },
    );
    final banners = await client.send('GET', '/api/v1/configs/banners') as List;
    expect((banners.single as Map)['content'], 'Maintenance tonight');
    await client.send(
      'POST',
      '/api/v1/configs/banners',
      body: {'banners': <Object>[]},
    );

    // A change is kept.
    final tasks = adminConfigSections.firstWhere(
      (s) => s.title == 'Interface and tasks',
    );
    final before = (await client.send('GET', tasks.read) as Map)
        .cast<String, dynamic>();
    final was = before['ENABLE_TAGS_GENERATION'] as bool;
    await client.send(
      'POST',
      tasks.save,
      body: {...before, 'ENABLE_TAGS_GENERATION': !was},
    );
    expect(
      (await client.send('GET', tasks.read) as Map)['ENABLE_TAGS_GENERATION'],
      !was,
    );
    await client.send('POST', tasks.save, body: before);
  }, skip: skip);

  test('a subgroup\'s members show in its parent, with a preview', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final parent = await client.send(
      'POST',
      '/api/v1/groups/create',
      body: {'name': 'nexus parent', 'description': ''},
    );
    final child = await client.send(
      'POST',
      '/api/v1/groups/create',
      body: {
        'name': 'nexus child',
        'description': '',
        'parent_group_id': parent['id'],
      },
    );
    addTearDown(() async {
      await client.send('DELETE', '/api/v1/groups/id/${child['id']}/delete');
      await client.send('DELETE', '/api/v1/groups/id/${parent['id']}/delete');
    });
    final me = await client.send('GET', '/api/v1/auths/');
    await client.send(
      'POST',
      '/api/v1/groups/id/${child['id']}/users/add',
      body: {
        'user_ids': [me['id']],
      },
    );
    final inherited = await client.send(
      'GET',
      '/api/v1/groups/id/${parent['id']}/members',
      query: {'membership': 'inherited'},
    );
    expect([for (final u in inherited['items']) u['id']], contains(me['id']));
    final all = [
      for (final g in await client.send('GET', '/api/v1/groups/') as List)
        (g as Map).cast<String, dynamic>(),
    ];
    expect(groupAndBelow(all, '${parent['id']}'), contains(child['id']));
    final preview = await client.send(
      'GET',
      '/api/v1/groups/id/${parent['id']}/preview',
    );
    expect(preview['models'], contains('items'));
  }, skip: skip);

  test('groups give permissions to their members', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final base = await client.send(
      'GET',
      '/api/v1/users/default/permissions/defaults',
    ) as Map;
    final group = await client.send(
      'POST',
      '/api/v1/groups/create',
      body: {'name': 'nexus test group', 'description': ''},
    ) as Map;
    final at = '/api/v1/groups/id/${group['id']}';
    try {
      final perms = permissionsFor(base, null, fill: true);
      (perms['features'] as Map)['notes'] = true;
      await client.send(
        'POST',
        '$at/update',
        body: {
          'name': 'renamed group',
          'description': 'd',
          'permissions': perms,
          'data': group['data'],
          'parent_group_id': null,
        },
      );
      final fresh = await client.send('GET', at) as Map;
      expect(fresh['name'], 'renamed group');
      expect((fresh['permissions'] as Map)['features']['notes'], isTrue);
      expect((fresh['permissions'] as Map)['chat']['delete'], isFalse);

      final me = await client.send('GET', '/api/v1/auths/') as Map;
      await client.send(
        'POST',
        '$at/users/add',
        body: {
          'user_ids': [me['id']],
        },
      );
      final members = await client.send(
        'GET',
        '$at/members',
        query: {'membership': 'direct'},
      ) as Map;
      expect((members['items'] as List).single['id'], me['id']);
      await client.send(
        'POST',
        '$at/users/remove',
        body: {
          'user_ids': [me['id']],
        },
      );

      // Default permissions save and come back.
      final defaults =
          await client.send('GET', '/api/v1/users/default/permissions') as Map;
      await client.send(
        'POST',
        '/api/v1/users/default/permissions',
        body: defaults,
      );
    } finally {
      await client.send('DELETE', '$at/delete');
    }
  }, skip: skip);

  test('adds, checks and removes a model connection', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final before = await client.send('GET', '/openai/config') as Map;
    final list = readConnections(openAiConnections, before);
    final first = list.first;
    // The connection the server already uses answers.
    await client.send(
      'POST',
      '/openai/verify',
      body: {'url': first.url, 'key': first.key, 'config': first.config},
    );
    list.add(
      Connection(
        url: 'http://127.0.0.1:9/v1',
        key: 'k',
        config: {'prefix_id': 'z'},
      ),
    );
    try {
      await client.send(
        'POST',
        '/openai/config/update',
        body: writeConnections(openAiConnections, true, list),
      );
      final after = readConnections(
        openAiConnections,
        await client.send('GET', '/openai/config') as Map,
      );
      expect(after.length, list.length);
      expect(after.last.key, 'k');
      expect(after.last.config['prefix_id'], 'z');
      await expectLater(
        client.send(
          'POST',
          '/openai/verify',
          body: {
            'url': after.last.url,
            'key': 'k',
            'config': <String, dynamic>{},
          },
        ),
        throwsA(isA<ApiException>()),
      );
    } finally {
      await client.send('POST', '/openai/config/update', body: {...before});
    }
  }, skip: skip);
}
