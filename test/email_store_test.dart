import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/email/email_agent.dart';

Map<String, dynamic> _e(String id, {bool unread = true, String date = ''}) => {
  'id': id,
  'subject': 's$id',
  'date': date,
  'unread': unread,
};

void main() {
  test('read marks from the app win over what Gmail said', () {
    final store = {
      'inbox': [_e('a'), _e('b'), _e('c', unread: false)],
      'read': {'a': true, 'c': false},
    };
    final kept = keptIn(store, 'inbox');
    expect([for (final e in kept) e.unread], [false, true, true]);
  });

  test('a new check keeps what was read', () {
    // Nexus lists "a" as unread again, since opening it in the app doesn't
    // touch Gmail.
    final merged = mergeEmails([Email.fromJson(_e('a'))], const []);
    final shown = withReadState(merged, {'a': true});
    expect(shown.single.unread, isFalse);
  });

  test('checks only when the last one is old', () {
    final now = DateTime(2026, 10, 27, 12);
    expect(needsCheck(null, now: now), isTrue);
    expect(
      needsCheck(now.subtract(const Duration(minutes: 3)), now: now),
      isFalse,
    );
    expect(
      needsCheck(now.subtract(const Duration(hours: 1)), now: now),
      isTrue,
    );
    final store = {
      'checked': {'inbox': now.toUtc().toIso8601String()},
    };
    expect(checkedIn(store, 'inbox'), now);
    expect(checkedIn(store, 'sent'), isNull);
  });

  test('the server copy wins unless the phone has unsaved changes', () {
    final server = {
      'inbox': [_e('a')],
      'read': {'a': false},
      'opened': {'a': {}},
    };
    final synced = mergeStores(server, {
      'inbox': [_e('x')],
      'read': {'a': true},
      'synced': true,
    });
    expect(keptIn(synced, 'inbox').map((e) => e.id), ['a']);
    expect(synced['read'], {'a': false});

    final unsaved = mergeStores(server, {
      'inbox': [_e('b')],
      'read': {'a': true},
      'synced': false,
    });
    expect(keptIn(unsaved, 'inbox').map((e) => e.id).toSet(), {'a', 'b'});
    expect(unsaved['read'], {'a': true});
    expect(unsaved['opened'], {'a': {}});
    expect(unsaved.containsKey('synced'), isFalse);
  });

  test('read marks for emails no longer kept are dropped', () {
    final store = pruneRead({
      'inbox': [_e('a')],
      'sent': [_e('b')],
      'read': {'a': true, 'b': true, 'gone': true},
    });
    expect(store['read'], {'a': true, 'b': true});
  });
}
