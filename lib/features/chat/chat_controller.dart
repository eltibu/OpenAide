import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../../core/models/model_info.dart';

const _uuid = Uuid();

/// Models come from the server every time, so anything added in Open WebUI
/// (new connections, custom models, presets) shows up without an app update.
final modelsProvider = FutureProvider<List<ModelInfo>>(
  (ref) => ref.watch(clientProvider).models(),
);

final chatListProvider = FutureProvider<List<ChatSummary>>(
  (ref) => ref.watch(clientProvider).chats(),
);

class ChatState {
  const ChatState({
    this.chat,
    this.modelId,
    this.streaming = false,
    this.loading = false,
    this.error,
    this.revision = 0,
  });

  final Chat? chat;
  final String? modelId;
  final bool streaming;
  final bool loading;
  final String? error;

  /// Bumped on every in-place change to [chat] so listeners rebuild.
  final int revision;

  List<ChatMessage> get messages => chat?.thread ?? const [];

  ChatState copyWith({
    Chat? chat,
    bool clearChat = false,
    String? modelId,
    bool? streaming,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => ChatState(
    chat: clearChat ? null : chat ?? this.chat,
    modelId: modelId ?? this.modelId,
    streaming: streaming ?? this.streaming,
    loading: loading ?? this.loading,
    error: clearError ? null : error ?? this.error,
    revision: revision + 1,
  );
}

class ChatController extends Notifier<ChatState> {
  StreamSubscription<String>? _sub;
  Completer<void>? _done;

  @override
  ChatState build() {
    ref.onDispose(() => _sub?.cancel());
    return const ChatState();
  }

  void selectModel(String id) => state = state.copyWith(modelId: id);

  void newChat() {
    _sub?.cancel();
    state = ChatState(modelId: state.modelId);
  }

  Future<void> open(String id) async {
    _sub?.cancel();
    state = state.copyWith(loading: true, clearChat: true, clearError: true);
    try {
      final chat = await ref.read(clientProvider).chat(id);
      state = state.copyWith(
        chat: chat,
        modelId: chat.models.firstOrNull ?? state.modelId,
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  /// Stops generation; the partial reply is kept and saved.
  void stop() {
    _sub?.cancel();
    _sub = null;
    if (_done?.isCompleted == false) _done!.complete();
  }

  Future<void> send(String text) async {
    final modelId = state.modelId;
    if (text.trim().isEmpty || modelId == null || state.streaming) return;
    final client = ref.read(clientProvider);
    state = state.copyWith(streaming: true, clearError: true);

    try {
      var chat = state.chat;
      final user = ChatMessage(
        id: _uuid.v4(),
        role: 'user',
        content: text.trim(),
        parentId: chat?.currentId,
        extra: {
          'models': [modelId],
        },
      );

      if (chat == null) {
        final draft = Chat(
          id: '',
          title: _titleFrom(user.content),
          messages: {},
          models: [modelId],
        )..append(user);
        // Created on the server first, so the chat exists there even if the
        // app is closed mid-reply.
        chat = await client.createChat(draft);
        state = state.copyWith(chat: chat);
        await _reply(chat, modelId, isFirstTurn: true);
      } else {
        chat
          ..models = [modelId]
          ..append(user);
        await _reply(chat, modelId);
      }
    } catch (e) {
      state = state.copyWith(streaming: false, error: '$e');
    }
  }

  /// Retries whatever failed last: a reply that never arrived is requested
  /// again; a reply that arrived but wasn't saved is saved again.
  Future<void> retry() async {
    final chat = state.chat;
    final modelId = state.modelId;
    if (state.streaming || chat == null || modelId == null) {
      ref.invalidate(modelsProvider);
      state = state.copyWith(clearError: true);
      return;
    }
    final tip = chat.messages[chat.currentId];
    state = state.copyWith(clearError: true);
    if (tip != null && tip.role == 'assistant' && tip.content.isEmpty) {
      // Drop the empty reply and ask again from its user message.
      final parent = chat.messages[tip.parentId];
      parent?.childrenIds.remove(tip.id);
      chat.messages.remove(tip.id);
      chat.currentId = parent?.id;
    }
    final last = chat.messages[chat.currentId];
    if (last != null && last.role == 'user') {
      state = state.copyWith(streaming: true);
      await _reply(chat, modelId);
    } else {
      await _save(chat);
    }
  }

  /// Streams an assistant reply under the chat's current tip, then saves.
  Future<void> _reply(
    Chat chat,
    String modelId, {
    bool isFirstTurn = false,
  }) async {
    final client = ref.read(clientProvider);
    final assistant = ChatMessage(
      id: _uuid.v4(),
      role: 'assistant',
      content: '',
      parentId: chat.currentId,
      model: modelId,
    );
    chat.append(assistant);
    state = state.copyWith(chat: chat);

    final history = [
      for (final m in chat.thread)
        if (m.id != assistant.id) {'role': m.role, 'content': m.content},
    ];

    final done = _done = Completer<void>();
    _sub = client
        .streamCompletion(model: modelId, messages: history)
        .listen(
          (delta) {
            assistant.content += delta;
            state = state.copyWith();
          },
          onError: (Object e) {
            state = state.copyWith(error: '$e');
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
    await done.future;
    _sub = null;
    assistant.extra['done'] = true;
    state = state.copyWith(streaming: false);
    // An empty reply isn't saved; Retry asks for it again.
    if (assistant.content.isEmpty) return;

    if (isFirstTurn) {
      final title = await client.generateTitle(modelId, [
        ...history,
        {'role': 'assistant', 'content': assistant.content},
      ]);
      // Servers can turn title generation off; then, like the web UI, the
      // chat keeps the first message as its name.
      if (title != null && title.isNotEmpty) chat.title = title;
    }
    await _save(chat);
  }

  /// Writes the chat back to the server.
  Future<void> _save(Chat chat) async {
    try {
      await ref.read(clientProvider).saveChat(chat);
      state = state.copyWith();
      ref.invalidate(chatListProvider);
    } catch (e) {
      state = state.copyWith(error: 'Reply not saved to server yet. $e');
    }
  }
}

String _titleFrom(String text) {
  final line = text.trim().split('\n').first;
  return line.length <= 50 ? line : '${line.substring(0, 50).trimRight()}…';
}

final chatControllerProvider = NotifierProvider<ChatController, ChatState>(
  ChatController.new,
);
