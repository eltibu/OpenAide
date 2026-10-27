// Runs against a real Open WebUI server with channels on; see
// server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/chat_socket.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/channels/channels_api.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('posts, reacts, threads and hears a model live', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final api = ChannelsApi(client);
    final channel = (await api.list()).firstWhere((c) => !c.isDm);
    final socket = ChatSocket(baseUrl: url, token: client.token!);
    await socket.ready();
    final events = <Map<String, dynamic>>[];
    final sub = socket.channelEvents.listen(events.add);
    try {
      final hello = await api.post(channel.id, 'hello from nexus');
      expect((await api.messages(channel.id)).first.id, hello.id);

      await api.react(channel.id, hello.id, '👍', true);
      var fresh = await api.message(channel.id, hello.id);
      expect(fresh.reactions.single.name, '👍');
      expect(fresh.reactions.single.count, 1);
      await api.react(channel.id, hello.id, '👍', false);
      expect((await api.message(channel.id, hello.id)).reactions, isEmpty);

      // Asking a model: it answers in a thread under the question.
      final models =
          ((await client.send('GET', '/api/models')) as Map)['data'] as List;
      final m = models.first as Map;
      final ask = await api.post(
        channel.id,
        '<@M:${m['id']}|${m['name']}> say hi',
      );
      List<ChannelMessage> replies = const [];
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        replies = await api.thread(channel.id, ask.id);
        if (replies.isNotEmpty && replies.first.done) break;
      }
      expect(replies, isNotEmpty);
      expect(replies.first.modelName, isNotNull);
      expect(replies.first.done, isTrue);
      expect(replies.first.content, isNotEmpty);
      expect(showMentions(ask.content), '**@${m['name']}** say hi');

      await api.post(channel.id, 'me too', parentId: ask.id);
      replies = await api.thread(channel.id, ask.id);
      expect(replies.first.content, 'me too');

      expect(
        events.any(
          (e) => e['channel_id'] == channel.id && e['message_id'] == hello.id,
        ),
        isTrue,
      );
      expect(
        events.any((e) => (e['data'] as Map)['type'] == 'message:update'),
        isTrue,
      );

      await api.edit(channel.id, hello.id, 'edited');
      fresh = await api.message(channel.id, hello.id);
      expect(fresh.content, 'edited');
      await api.delete(channel.id, hello.id);
      await api.delete(channel.id, ask.id);
    } finally {
      await sub.cancel();
      socket.dispose();
    }
  }, skip: skip);
}
