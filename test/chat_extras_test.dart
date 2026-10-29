import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/chat/chat_extras.dart';

void main() {
  final chat = Chat.fromServer({
    'id': 'c1',
    'title': 'Trip: plans / ideas',
    'chat': {
      'history': {
        'currentId': 'a',
        'messages': {
          'u': {
            'id': 'u',
            'role': 'user',
            'content': 'Hi',
            'childrenIds': ['a'],
          },
          'a': {
            'id': 'a',
            'role': 'assistant',
            'content': 'Hello',
            'parentId': 'u',
            'model': 'nexus',
            'childrenIds': <String>[],
          },
        },
      },
    },
  });

  test('exports text the way the web does', () {
    expect(chatAsText(chat), '### USER\nHi\n\n### ASSISTANT\nHello');
    expect(chatAsMarkdown(chat), contains('**nexus**\n\nHello'));
    expect(chatFileName(chat.title, 'txt'), 'Trip plans ideas.txt');
    expect(chatFileName('', 'pdf'), 'chat.pdf');
  });

  test('share audiences match the web grants', () {
    for (final a in ShareAudience.values) {
      expect(audienceOf(shareGrants(a)), a);
    }
    expect(
      shareGrants(ShareAudience.anyone).single['principal_type'],
      'anyone',
    );
  });
}
