import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/settings/about_screen.dart';

void main() {
  test('reads release notes as the web shows them', () {
    final notes = parseChangelog({
      '0.12.4': {
        'date': '2026-10-25',
        'added': [
          {
            'title': '',
            'content': 'plain',
            'raw': '<li>🎯 <strong>Skills.</strong> On &amp; off</li>',
          },
          {'content': 'only content'},
          {'raw': ''},
        ],
        'fixed': <Object>[],
      },
      'junk': 'x',
    });
    expect(notes, hasLength(1));
    expect(notes.single.version, '0.12.4');
    expect(notes.single.sections.first.$1, 'added');
    expect(notes.single.sections.first.$2, [
      '🎯 Skills. On & off',
      'only content',
    ]);
    expect(notes.single.sections.last.$2, isEmpty);
    expect(releaseDate('2026-10-25'), 'Oct 25, 2026');
    expect(releaseDate('soon'), 'soon');
  });

  test('compares versions', () {
    expect(isNewer('0.12.5', '0.12.4'), isTrue);
    expect(isNewer('v0.13.0', '0.12.10'), isTrue);
    expect(isNewer('0.12.4', '0.12.4'), isFalse);
    expect(isNewer('0.12.3', '0.12.10'), isFalse);
  });

  test("What's New opens once per server version, for admins", () {
    bool now(String role, Map ui) =>
        showWhatsNewNow(role: role, ui: ui, serverVersion: '0.12.4');
    expect(now('admin', {}), isTrue);
    expect(now('admin', {'version': '0.12.4'}), isFalse);
    expect(
      now('admin', {'version': '0.12.3', 'showChangelog': false}),
      isFalse,
    );
    expect(now('user', {}), isFalse);
  });

  final url = Platform.environment['OWUI_URL'];
  test('the server sends notes it can read', () async {
    HttpOverrides.global = null;
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(
      Platform.environment['OWUI_EMAIL']!,
      Platform.environment['OWUI_PASSWORD']!,
    );
    final notes = parseChangelog(await client.send('GET', '/api/changelog'));
    expect(notes, isNotEmpty);
    expect(notes.first.sections.expand((s) => s.$2), isNotEmpty);
    final v = await client.send('GET', '/api/version/updates') as Map;
    expect(v['current'], isNotNull, reason: jsonEncode(v));
  }, skip: url == null ? 'Set OWUI_URL' : null);
}
