import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/chat/chat_drawer.dart';

void main() {
  ChatSummary at(String id, DateTime t) =>
      ChatSummary(id: id, title: id, updatedAt: t);

  test('chats group by when they were used, as in the web sidebar', () {
    final now = DateTime(2026, 10, 27, 13);
    final groups = groupByWhen([
      at('a', DateTime(2026, 10, 27, 9)),
      at('b', DateTime(2026, 10, 27, 0, 5)),
      at('c', DateTime(2026, 10, 26, 23)),
      at('d', DateTime(2026, 10, 22)),
      at('e', DateTime(2026, 10, 5)),
      at('f', DateTime(2026, 8, 3)),
      at('g', DateTime(2025, 12, 31)),
    ], now);
    expect(
      [
        for (final (label, chats) in groups)
          '$label: ${chats.map((c) => c.id).join()}',
      ],
      [
        'Today: ab',
        'Yesterday: c',
        'Previous 7 days: d',
        'Previous 30 days: e',
        'August: f',
        'December 2025: g',
      ],
    );
  });
}
