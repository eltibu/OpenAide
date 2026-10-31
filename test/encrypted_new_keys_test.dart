// A guest's new keys wait for the host, and MLS seals nothing meanwhile:
// what the guest sends then (a receipt, typing, a message) has to wait for
// the host's commit instead of ending the chat.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/channels/encrypted_conversation.dart';
import 'package:nexus_assistant/features/channels/mls.dart';

/// The server's relay (open_webui/socket/encryption.py), in memory: one
/// session, packets forwarded in order to everyone admitted but the sender.
class _Hub {
  final members = <String, Map<String, dynamic>>{};
  String? host;
  final session = 'sess';
  var _n = 0;

  /// People whose packets are held back until [release].
  final held = <String>{};
  final _waiting = <String, List<Map<String, dynamic>>>{};

  Map<String, dynamic> view() => {
    'channel': 'c',
    'session': session,
    'host': host,
    'bindings': [
      for (final e in members.entries)
        if (e.value['key'] != null)
          {
            'identity': {
              'channel': 'c',
              'session': session,
              'user': e.value['user'],
              'participation': e.key,
            },
            'key': e.value['key'],
          },
    ],
    'participants': [
      for (final e in members.entries)
        {
          'participation': e.key,
          'user': e.value['user'],
          'name': e.value['user'],
        },
    ],
  };

  void deliver(List<String> to, Map<String, dynamic> event) {
    for (final pid in to) {
      final m = members[pid]!;
      m['out'] = (m['out'] as int) + 1;
      final e = {...event, ...view(), 'sequence': m['out']};
      if (held.contains(pid)) {
        _waiting.putIfAbsent(pid, () => []).add(e);
      } else {
        (m['relay'] as _Relay)._events.add(e);
      }
    }
  }

  void release(String pid) {
    held.remove(pid);
    for (final e in _waiting.remove(pid) ?? const []) {
      (members[pid]!['relay'] as _Relay)._events.add(e);
    }
  }

  Map<String, dynamic> handle(_Relay relay, String action, Map data) {
    if (action == 'start' || action == 'join') {
      final pid = 'p${_n++}';
      host ??= pid;
      members[pid] = {
        'user': relay.user,
        'key': null,
        'out': 0,
        'admitted': action == 'start',
        'relay': relay,
      };
      relay.pid = pid;
      return {'ok': true, ...view(), 'participation': pid};
    }
    final pid = data['participation'] as String;
    final m = members[pid]!;
    switch (action) {
      case 'bind':
        m['key'] = data['key'];
        if (pid != host) {
          deliver(
            [host!],
            {'kind': 'candidate', 'sender': pid, 'packet': data['packet']},
          );
        }
      case 'packet':
        final others = [
          for (final e in members.entries)
            if (e.key != pid && e.value['admitted'] == true) e.key,
        ];
        if (data['kind'] == 'admit') {
          final target = data['target'] as String;
          members[target]!['admitted'] = true;
          deliver(others.where((o) => o != target).toList(), {
            'kind': 'mls',
            'sender': pid,
            'packet': data['packet'],
          });
          deliver(
            [target],
            {'kind': 'welcome', 'sender': pid, 'packet': data['welcome']},
          );
        } else {
          deliver(others, {
            'kind': 'mls',
            'sender': pid,
            'packet': data['packet'],
          });
        }
    }
    return {'ok': true, ...view()};
  }
}

class _Relay implements EncryptionRelay {
  _Relay(this.hub, this.user);
  final _Hub hub;
  final String user;
  String pid = '';
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  Stream<void> get dropped => const Stream.empty();
  @override
  Future<Map<String, dynamic>> request(String action, Map data) async =>
      hub.handle(this, action, data);
}

void main() {
  final skip = mlsAvailable ? null : 'Build native/encryption first';

  Future<void> until(bool Function() done, String what) async {
    for (var i = 0; i < 200; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting for $what');
  }

  test('a message reaching a guest whose new keys wait is kept', () async {
    final hub = _Hub();
    final hostRelay = _Relay(hub, 'u0');
    final guestRelay = _Relay(hub, 'u1');
    final mine = EncryptedConversation(hostRelay, channel: 'c', user: 'u0');
    addTearDown(mine.dispose);
    await until(() => mine.status == EncryptedStatus.active, 'the start');
    final theirs = EncryptedConversation(
      guestRelay,
      channel: 'c',
      user: 'u1',
      session: hub.session,
    );
    addTearDown(theirs.dispose);
    await until(() => theirs.status == EncryptedStatus.active, 'the join');

    // The host's message crosses the guest's new keys.
    hub.held.add(hostRelay.pid);
    await theirs.updateKeys();
    await mine.sendText('after new keys');
    await until(
      () => theirs.messages.any((m) => m.text == 'after new keys'),
      'the message',
    );
    // The guest's own message waits for the host, then goes.
    await theirs.sendText('me too');
    expect(theirs.status, EncryptedStatus.active);
    hub.release(hostRelay.pid);
    await until(() => mine.messages.any((m) => m.text == 'me too'), 'reply');
    await until(
      () => mine.messages
          .firstWhere((m) => m.text == 'after new keys')
          .received
          .isNotEmpty,
      'the receipt',
    );
    await mine.sendText('and again');
    await until(
      () => theirs.messages.any((m) => m.text == 'and again'),
      'a message on the new keys',
    );
    expect(mine.status, EncryptedStatus.active);
    expect(theirs.status, EncryptedStatus.active);
  }, skip: skip);
}
