import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/in_app_toasts.dart';
import 'package:nexus_assistant/features/email/email_agent.dart'
    show appWorkingChats;

Map reply(String chat, {bool done = true}) => {
  'chat_id': chat,
  'data': {
    'type': 'chat:completion',
    'data': {'done': done, 'content': 'All **done** here', 'title': 'Taxes'},
  },
};

Map message(String channel, {String from = 'u2', String content = 'hi'}) => {
  'channel_id': channel,
  'channel': {'name': 'general', 'type': ''},
  'data': {
    'type': 'message',
    'data': {
      'content': content,
      'user': {'id': from, 'name': 'Rosanna'},
    },
  },
};

void main() {
  test("the app's own email chat makes no toast", () {
    expect(chatEventToast(reply('c2'), hiddenChat: 'c2'), isNull);
    appWorkingChats.add('c3');
    expect(chatEventToast(reply('c3')), isNull);
    appWorkingChats.remove('c3');
  });

  test('finished replies in other chats', () {
    final t = chatEventToast(reply('c2'), openChat: 'c1');
    expect(t, isA<ReplyToast>());
    expect(t!.title, 'Taxes');
    expect(t.text, 'All done here');
    expect((t as ReplyToast).chatId, 'c2');
    expect(chatEventToast(reply('c1'), openChat: 'c1'), isNull);
    expect(chatEventToast(reply('c2', done: false), openChat: 'c1'), isNull);
  });

  test('calendar alerts', () {
    Map alert(int m) => {
      'data': {
        'type': 'calendar:alert',
        'data': {'title': 'Dentist', 'minutes_until': m},
      },
    };
    expect(chatEventToast(alert(0))!.text, 'Starting now');
    expect(chatEventToast(alert(1))!.text, 'Starting in 1 minute');
    expect(chatEventToast(alert(10))!.text, 'Starting in 10 minutes');
    expect(chatEventToast(alert(10)), isA<CalendarToast>());
  });

  test('channel messages', () {
    Toast? t(Map e, {List<String> open = const [], bool muted = false}) =>
        channelEventToast(e, me: 'u1', open: open, muted: (_) => muted);
    final toast = t(message('ch1', content: 'see <#ch9|plans> <@U:u1|Joel>'));
    expect(toast!.title, 'Rosanna (#general)');
    expect(toast.text, 'see #plans @Joel');
    expect(t(message('ch1'), open: ['ch1']), isNull);
    expect(t(message('ch1', from: 'u1')), isNull);
    expect(t(message('ch1'), muted: true), isNull);
    expect(
      t(message('ch1', content: 'hey <@U:u1|Joel>'), muted: true),
      isNotNull,
    );
  });
}
