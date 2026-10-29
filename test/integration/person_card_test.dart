// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/channels/person_card.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test("a person's card reads their status and groups", () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final me = (await client.send('GET', '/api/v1/auths/')) as Map;
    final p = await personInfo(client, '${me['id']}');
    expect(p.id, me['id']);
    expect(p.name, me['name']);
    expect(p.groups, isA<List<String>>());
  }, skip: skip);

  test('last seen reads like the web', () {
    final now = DateTime(2026, 10, 28, 12);
    expect(
      sinceLabel(now.subtract(const Duration(seconds: 20)), now),
      'just now',
    );
    expect(
      sinceLabel(now.subtract(const Duration(minutes: 1)), now),
      '1 minute ago',
    );
    expect(
      sinceLabel(now.subtract(const Duration(hours: 3)), now),
      '3 hours ago',
    );
    expect(
      sinceLabel(now.subtract(const Duration(days: 40)), now),
      '1 month ago',
    );
  });

  test('status, bio and groups come from the server record', () {
    final p = PersonInfo.fromJson({
      'id': 'u1',
      'name': 'Rosanna',
      'is_active': false,
      'status_emoji': '🌴',
      'status_message': 'On holiday',
      'bio': ' ',
      'last_active_at': 1793160000,
      'timezone': 'Europe/Madrid',
      'groups': [
        {'id': 'g', 'name': 'Family'},
      ],
    });
    expect(p.statusEmoji, '🌴');
    expect(p.bio, isNull);
    expect(p.groups, ['Family']);
    expect(p.lastSeen!.year, 2026);
  });
}
