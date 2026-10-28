import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/standalone/local_chats.dart';

void main() {
  test('chats without a server are saved, listed and deleted', () async {
    final dir = await Directory.systemTemp.createTemp('local_chats');
    addTearDown(() => dir.delete(recursive: true));
    final store = LocalChatStore(dir);
    final chat = Chat(
      id: 'c1',
      title: 'Hello',
      messages: {},
      models: ['direct:anthropic:claude-x'],
    );
    chat
      ..append(ChatMessage(id: 'u1', role: 'user', content: 'Hi'))
      ..append(
        ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'Hello!',
          parentId: 'u1',
          model: 'direct:anthropic:claude-x',
        ),
      );
    await store.save(chat);
    final list = await store.list();
    expect(list.single.title, 'Hello');
    final back = (await store.load('c1'))!;
    expect(back.thread.map((m) => m.content), ['Hi', 'Hello!']);
    expect(back.thread.last.model, 'direct:anthropic:claude-x');
    await store.delete('c1');
    expect(await store.list(), isEmpty);
  });
}
