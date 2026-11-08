// Open WebUI 0.13 additions that need no server.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/chat/side_chat.dart';
import 'package:nexus_assistant/features/comments/comments.dart';
import 'package:nexus_assistant/features/inbox/inbox.dart';
import 'package:nexus_assistant/features/terminal/file_tools.dart';
import 'package:nexus_assistant/features/terminal/terminal_api.dart';
import 'package:nexus_assistant/features/workspace/prompts_api.dart';

void main() {
  test('a chat waiting for approval is marked in the list', () {
    final waiting = ChatSummary.fromJson({
      'id': 'a',
      'title': 't',
      'updated_at': 1,
      'pending_approval': true,
    });
    final plain = ChatSummary.fromJson({'id': 'b', 'title': 't'});
    expect(waiting.waitingForApproval, isTrue);
    expect(plain.waitingForApproval, isFalse);
  });

  test('/side and /btw are side chat questions', () {
    expect(sideChatQuestion('/side what is a monad?'), 'what is a monad?');
    expect(sideChatQuestion('/btw  quick one'), 'quick one');
    expect(sideChatQuestion('/side'), '');
    expect(sideChatQuestion('/sidewalk'), isNull);
    expect(sideChatQuestion('hello /side'), isNull);
  });

  test('side chats: admins, and people given the permission', () {
    expect(sideChatAllowed({'role': 'admin'}), isTrue);
    expect(sideChatAllowed({'role': 'user'}), isFalse);
    expect(
      sideChatAllowed({
        'role': 'user',
        'permissions': {
          'chat': {'side_chat': true},
        },
      }),
      isTrue,
    );
    expect(
      sideChatAllowed({
        'role': 'user',
        'permissions': {
          'chat': {'side_chat': true, 'temporary': false},
        },
      }),
      // Open WebUI 0.13.1 dropped the need for Temporary Chat.
      isTrue,
    );
    expect(sideChatAllowed({'role': 'pending'}), isFalse);
  });

  test('a passage anchor counts characters as the server does', () {
    const content = 'Café 😀 is four, as always.';
    final a = CommentAnchor.find(quote: 'four', content: content)!;
    expect(a.quote, 'four');
    // "Café 😀 is " is 10 characters, though 11 UTF-16 units.
    expect(a.json['start'], 10);
    expect(a.json['end'], 14);
    expect(a.json['prefix'], 'Café 😀 is ');
    expect(a.json['suffix'], ', as always.');
    expect(
      a.json['content_hash'],
      sha256.convert(utf8.encode(content)).toString(),
    );
    expect(CommentAnchor.find(quote: 'five', content: content), isNull);
    expect(CommentAnchor.find(quote: '  ', content: content), isNull);
  });

  test('only saved chats take comments', () {
    expect(commentableChat('3f1c'), isTrue);
    expect(commentableChat(''), isFalse);
    expect(commentableChat(null), isFalse);
    expect(commentableChat('temporary:abc:def'), isFalse);
    expect(commentableChat('local:abc'), isFalse);
  });

  test('inbox items read as the web words them', () {
    InboxItem item(String event, [String actor = 'Ana']) => InboxItem({
      'id': '1',
      'event_type': event,
      'actor': {'id': 'u', 'name': actor},
      'created_at': '1730000000000000000',
    });
    expect(item('comment.created').label, 'Ana commented');
    expect(item('comment.replied').label, 'Ana replied');
    expect(item('channel.mentioned').label, 'Ana mentioned you');
    expect(item('calendar.alert').label, 'Upcoming event');
    expect(item('automation.run_failed').label, 'Automation failed');
    expect(item('something.new').label, 'Notification');
    expect(item('comment.created').created.year, 2024);
    expect(item('comment.created').read, isFalse);
  });

  test('{{USER_ROLE}} is filled with the role', () {
    expect(
      fillSystemVariables('You help a {{USER_ROLE}}.', userRole: 'admin'),
      'You help a admin.',
    );
    expect(fillSystemVariables('{{USER_ROLE}}'), 'Unknown');
    expect(systemVariables, contains('USER_ROLE'));
  });

  test('files sort by date added; undated ones last', () {
    TerminalEntry e(String name, int? added) => TerminalEntry(
      name: name,
      path: '/$name',
      isDir: false,
      created: added == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(added * 1000),
    );
    final sorted = sortEntries([
      e('c', 30),
      e('none', null),
      e('a', 10),
      e('b', 20),
    ], FileSort.created);
    expect(sorted.map((x) => x.name), ['a', 'b', 'c', 'none']);
    final reversed = sortEntries(
      [e('c', 30), e('none', null), e('a', 10), e('b', 20)],
      FileSort.created,
      descending: true,
    );
    expect(reversed.map((x) => x.name), ['c', 'b', 'a', 'none']);
  });
}
