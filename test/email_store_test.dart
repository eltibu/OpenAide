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

  group('an opened email read as OpenAide writes it', () {
    const e = Email(id: 'm1', subject: 'Hi');
    const answer =
        '=== From: Ann <ann@x.com> | To: Joel <j@x.com> | Date: 2026-10-28T10:00:00Z\n'
        '# Hello\n\nSee [the plan](https://x.com/plan).\n'
        '=== From: Joel <j@x.com> | To: Ann <ann@x.com> | Date: 2026-10-28T11:00:00Z\n'
        'Thanks!\n'
        '=== SUMMARY\n'
        'Ann shared the plan.\n'
        '=== REPLY\n'
        'Looks good.';

    test('keeps each message, the summary and the reply', () {
      final o = openedFromText(answer, e)!;
      expect(o.messages.length, 2);
      expect(o.messages.first.from, 'Ann <ann@x.com>');
      expect(o.messages.first.to, 'Joel <j@x.com>');
      expect(o.messages.first.date?.toUtc(), DateTime.utc(2026, 10, 28, 10));
      expect(
        o.messages.first.body,
        '# Hello\n\nSee [the plan](https://x.com/plan).',
      );
      expect(o.messages.last.body, 'Thanks!');
      expect(o.summary, 'Ann shared the plan.');
      expect(o.suggestedReply, 'Looks good.');
    });

    test('shows what has come while it is still being written', () {
      final o = openedFromText(answer.substring(0, 100), e)!;
      expect(o.messages.single.from, 'Ann <ann@x.com>');
      expect(o.messages.single.body, startsWith('# Hel'));
      expect(o.summary, isEmpty);
      expect(openedFromText('Let me open it…', e), isNull);
      expect(openedFromText('{"messages": []}', e), isNull);
    });
  });
}
