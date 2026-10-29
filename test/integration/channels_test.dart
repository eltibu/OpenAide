// Runs against a real Open WebUI server with channels on; see
// server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/chat_socket.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/models/chat.dart' show Attachment;
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

  test('pins, mutes, manages members, webhooks, groups and DMs', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final api = ChannelsApi(client);

    // Someone else to add.
    var others = [
      for (final u in await api.searchUsers(''))
        if (u.email != email) u,
    ];
    if (others.isEmpty) {
      await client.send(
        'POST',
        '/api/v1/auths/add',
        body: {
          'name': 'Friend',
          'email': 'friend@t.io',
          'password': 'Passw0rd!x',
          'role': 'user',
        },
      );
      others = [
        for (final u in await api.searchUsers('friend'))
          if (u.email != email) u,
      ];
    }
    final friend = others.first;

    final group = await api.create('nexus test', type: 'group');
    try {
      var c = await api.get(group.id);
      expect(c.isGroup, isTrue);
      expect(c.muted, isFalse);

      final m = await api.post(c.id, 'pin me');
      await api.pin(c.id, m.id, true);
      expect((await api.message(c.id, m.id)).pinned, isTrue);
      expect((await api.pinned(c.id)).map((x) => x.id), contains(m.id));
      await api.pin(c.id, m.id, false);
      expect(await api.pinned(c.id), isEmpty);

      final private = c.isPrivate;
      await api.update(c, isPrivate: !private);
      c = await api.get(c.id);
      expect(c.isPrivate, !private);
      expect(c.name, 'nexus test');

      await api.setMuted(c.id, true);
      expect((await api.get(c.id)).muted, isTrue);
      await api.setMuted(c.id, false);

      await api.addMembers(c.id, [friend.id]);
      expect((await api.members(c.id)).map((u) => u.id), contains(friend.id));
      expect((await api.get(c.id)).userCount, 2);
      await api.removeMembers(c.id, [friend.id]);
      expect(
        (await api.members(c.id)).map((u) => u.id),
        isNot(contains(friend.id)),
      );

      await api.update(c, name: 'renamed', description: 'about');
      c = await api.get(c.id);
      expect(c.name, 'renamed');
      expect(c.description, 'about');
      expect(c.isGroup, isTrue);

      // A file goes with a message and comes back with it.
      final uploaded = await client.uploadFile(
        'hello file'.codeUnits,
        'note.txt',
        contentType: 'text/plain',
      );
      final withFile = await api.post(
        c.id,
        'see attached',
        files: [Attachment.uploaded(uploaded, size: 10)],
      );
      final listed = (await api.messages(c.id))
          .firstWhere((x) => x.id == withFile.id);
      expect(listed.hasFiles, isTrue);
      final files = await api.files(c.id, withFile.id);
      expect(files.single.name, 'note.txt');
      expect(files.single.id, uploaded['id']);

      final hook = await api.createWebhook(c.id, 'CI');
      expect(
        hook.url(url),
        '$url/api/v1/channels/webhooks/${hook.id}/'
        '${hook.token}',
      );
      expect((await api.webhooks(c.id)).single.name, 'CI');
      // Posting to the address puts a message in the channel.
      await OpenWebUiClient(baseUrl: url).send(
        'POST',
        '/api/v1/channels/webhooks/${hook.id}/${hook.token}',
        body: {'content': 'from a webhook'},
      );
      expect((await api.messages(c.id)).first.content, 'from a webhook');
      await api.deleteWebhook(c.id, hook.id);
      expect(await api.webhooks(c.id), isEmpty);

      final dm = await api.directMessage(friend.id);
      expect(dm.isDm, isTrue);
      expect((await api.directMessage(friend.id)).id, dm.id);
      await api.setActive(dm.id, false);
    } finally {
      await api.deleteChannel(group.id);
    }
    expect((await api.list()).map((x) => x.id), isNot(contains(group.id)));
  }, skip: skip);
}
