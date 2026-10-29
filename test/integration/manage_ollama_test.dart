// Runs against a real Open WebUI server; see server_sync_test.dart. Needs an
// Ollama (or a stand-in) at OLLAMA_URL that the server can reach.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/admin/ollama_pulls.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final ollama = Platform.environment['OLLAMA_URL'];
  final skip = url == null || ollama == null
      ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD, OLLAMA_URL'
      : null;

  test('pull with progress, list and delete an Ollama model', () async {
    HttpOverrides.global = null;
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final before = (await client.send('GET', '/ollama/config') as Map)
        .cast<String, dynamic>();
    await client.send(
      'POST',
      '/ollama/config/update',
      body: {
        ...before,
        'ENABLE_OLLAMA_API': true,
        'OLLAMA_BASE_URLS': [ollama],
      },
    );
    addTearDown(
      () => client.send('POST', '/ollama/config/update', body: before),
    );

    final steps = await client.streamJson('POST', '/ollama/api/pull/0', {
      'name': 'pulled:1b',
    }).toList();
    expect(steps.last['status'], 'success');
    expect(steps.map(pullPercent).whereType<double>(), [50, 100]);

    List names(Object? tags) => [
      for (final m in (tags as Map)['models'] as List) m['name'],
    ];
    expect(
      names(await client.send('GET', '/ollama/api/tags/0')),
      contains('pulled:1b'),
    );
    await client.send(
      'DELETE',
      '/ollama/api/delete/0',
      body: {'model': 'pulled:1b'},
    );
    expect(
      names(await client.send('GET', '/ollama/api/tags/0')),
      isNot(contains('pulled:1b')),
    );
  }, skip: skip);

  test(
    'a shared pull shows progress, ends ready, and can be cancelled',
    () async {
      HttpOverrides.global = null;
      final client = OpenWebUiClient(baseUrl: url!);
      await client.signIn(email!, password!);
      final before = (await client.send('GET', '/ollama/config') as Map)
          .cast<String, dynamic>();
      await client.send(
        'POST',
        '/ollama/config/update',
        body: {
          ...before,
          'ENABLE_OLLAMA_API': true,
          'OLLAMA_BASE_URLS': [ollama],
        },
      );
      addTearDown(
        () => client.send('POST', '/ollama/config/update', body: before),
      );
      final container = ProviderContainer(
        overrides: [clientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);
      final pulls = container.read(ollamaPullsProvider.notifier);

      final seen = <String>{};
      container.listen(
        ollamaPullsProvider,
        (_, now) => seen.addAll(now.keys),
        fireImmediately: true,
      );
      final end = await pulls.pull('picked:1b');
      expect(end.$1, PullEnd.ready);
      expect(seen, contains('picked:1b'));
      expect(container.read(ollamaPullsProvider), isEmpty);

      final cancelled = pulls.pull('other:1b');
      pulls.cancel('other:1b');
      expect((await cancelled).$1, PullEnd.cancelled);
      expect(container.read(ollamaPullsProvider), isEmpty);

      await client.send(
        'DELETE',
        '/ollama/api/delete/0',
        body: {'model': 'picked:1b'},
      );
    },
    skip: skip,
  );
}
