import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/channels/mls.dart';

void main() {
  final skip = mlsAvailable ? null : 'Build native/encryption first';

  Map<String, String> who(int n) => {
    'channel': 'c',
    'session': 's',
    'user': 'u$n',
    'participation': 'p$n',
  };
  String roster(List<(int, MlsSession)> people) => jsonEncode([
    for (final (n, s) in people)
      {'identity': who(n), 'key': s.call('public_key')},
  ]);

  test('two people: a welcome, a message both ways, members', () {
    final host = MlsSession(who(0), 'p0');
    final guest = MlsSession(who(1), 'p0');
    addTearDown(host.dispose);
    addTearDown(guest.dispose);
    host.call('create');
    final bindings = roster([(0, host), (1, guest)]);
    final added = jsonDecode(
      host.call('add', guest.call('key_package') as String, 'p1', bindings)
          as String,
    ) as Map;
    guest.call('join', added['welcome'] as String, bindings);

    final hello = host.call('encrypt', 'hello') as String;
    final read = jsonDecode(
      guest.call('process', hello, 'p0', bindings) as String,
    );
    expect(read['kind'], 'application');
    expect(read['text'], 'hello');
    expect(read['sender']['participation'], 'p0');

    final back = guest.call('encrypt', 'hi back') as String;
    expect(
      jsonDecode(host.call('process', back, 'p1', bindings) as String)['text'],
      'hi back',
    );
    final members = jsonDecode(host.call('members') as String) as List;
    expect(members.map((m) => m['identity']['participation']), ['p0', 'p1']);
    expect((members.first['fingerprint'] as String).length, 64);
  }, skip: skip);

  test('a refused step ends the session', () {
    final s = MlsSession(who(0), 'p0');
    expect(() => s.call('members'), throwsA(isA<MlsException>()));
    expect(s.closed, isTrue);
    expect(() => s.call('public_key'), throwsA(isA<MlsException>()));
  }, skip: skip);
}
