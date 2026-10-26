import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../../core/models/model_info.dart';
import 'request_options.dart';

const _uuid = Uuid();

/// Models come from the server every time, so anything added in Open WebUI
/// (new connections, custom models, presets) shows up without an app update.
final modelsProvider = FutureProvider<List<ModelInfo>>(
  (ref) => ref.watch(clientProvider).models(),
);

/// The person's settings and the server's config, read once per sign-in for
/// what each message carries (memory, default features, params).
final userSettingsProvider = FutureProvider<Map<String, dynamic>>(
  (ref) => ref.watch(clientProvider).userSettings(),
);
final serverConfigProvider = FutureProvider<Map<String, dynamic>>(
  (ref) => ref.watch(clientProvider).config(),
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
    this.status,
    this.features = const {},
    this.attachments = const [],
    this.revision = 0,
  });

  final Chat? chat;
  final String? modelId;
  final bool streaming;
  final bool loading;
  final String? error;

  /// What the server says the reply is doing ("Searching the web", a tool).
  final String? status;

  /// Features the person switched on or off in this chat (web search...).
  final Map<String, bool> features;

  /// Photos and files waiting in the composer for the next message.
  final List<PendingAttachment> attachments;

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
    String? status,
    bool clearStatus = false,
    Map<String, bool>? features,
    List<PendingAttachment>? attachments,
  }) => ChatState(
    chat: clearChat ? null : chat ?? this.chat,
    modelId: modelId ?? this.modelId,
    streaming: streaming ?? this.streaming,
    loading: loading ?? this.loading,
    error: clearError ? null : error ?? this.error,
    status: clearStatus ? null : status ?? this.status,
    features: features ?? this.features,
    attachments: attachments ?? this.attachments,
    revision: revision + 1,
  );
}

/// A photo or file in the composer: uploading, uploaded, or failed.
class PendingAttachment {
  const PendingAttachment({
    required this.key,
    required this.name,
    required this.isImage,
    this.bytes,
    this.uploaded,
    this.error,
    this.warning,
  });

  final String key;
  final String name;
  final bool isImage;

  /// The photo itself, for the preview while it uploads.
  final List<int>? bytes;
  final Attachment? uploaded;
  final String? error;

  /// Sent anyway, but the server couldn't read it (the web UI's warning).
  final String? warning;

  bool get uploading => uploaded == null && error == null;
}

/// One reply the server is writing.
class _Run {
  _Run(this.reply);
  final ChatMessage reply;
  final finished = Completer<void>();
  List<String> taskIds = const [];

  /// Stop was tapped, possibly before the server returned task ids.
  bool stopped = false;

  void finish() {
    if (!finished.isCompleted) finished.complete();
  }
}

class ChatController extends Notifier<ChatState> {
  _Run? _run;

  /// Bumped whenever what's on screen changes (another chat, a new chat, a
  /// new account), so a fetch that finishes late can tell it is stale.
  int _view = 0;

  @override
  ChatState build() {
    // Another account (or signing out) starts from a clean slate, so the
    // previous account's chat never shows or receives messages.
    ref.watch(sessionProvider.select((s) => s.value?.token));
    ref.onDispose(() {
      _view++;
      _run?.finish();
    });
    // Connect early so the first reply streams live.
    Future.microtask(() {
      try {
        ref.read(chatSocketProvider);
      } catch (_) {}
    });
    return const ChatState();
  }

  void selectModel(String id) => state = state.copyWith(modelId: id);

  void setFeature(String id, bool on) =>
      state = state.copyWith(features: {...state.features, id: on});

  void newChat() {
    _view++;
    _run?.finish();
    state = ChatState(modelId: state.modelId, attachments: state.attachments);
  }

  /// Uploads a photo or file for the next message, like the web UI's attach
  /// button: photos are stored as they are, other files are also read by the
  /// server so the model can search them.
  Future<void> attach(List<int> bytes, String name, {String? mimeType}) async {
    final type = mimeType ?? _mimeFromName(name);
    final isImage = type != null && _isRaster(type);
    final key = _uuid.v4();
    if (bytes.isEmpty) {
      state = state.copyWith(error: "$name is empty, so it can't be sent.");
      return;
    }
    state = state.copyWith(
      attachments: [
        ...state.attachments,
        PendingAttachment(
          key: key,
          name: name,
          isImage: isImage,
          bytes: isImage ? bytes : null,
        ),
      ],
    );
    PendingAttachment done;
    try {
      final client = ref.read(clientProvider);
      final uploaded = await client.uploadFile(
        bytes,
        name,
        contentType: type,
        process: !isImage,
      );
      final warning = isImage
          ? null
          : await client.waitForFile(uploaded['id'] as String);
      done = PendingAttachment(
        key: key,
        name: name,
        isImage: isImage,
        bytes: isImage ? bytes : null,
        uploaded: Attachment.uploaded(uploaded, size: bytes.length),
        warning: warning,
      );
    } catch (e) {
      done = PendingAttachment(
        key: key,
        name: name,
        isImage: isImage,
        error: '$e',
      );
    }
    // Removed while it uploaded: leave it out.
    if (!state.attachments.any((a) => a.key == key)) return;
    state = state.copyWith(
      attachments: [for (final a in state.attachments) a.key == key ? done : a],
    );
  }

  void removeAttachment(String key) => state = state.copyWith(
    attachments: [
      for (final a in state.attachments)
        if (a.key != key) a,
    ],
  );

  Future<void> open(String id) async {
    final view = ++_view;
    _run?.finish();
    state = state.copyWith(
      loading: true,
      streaming: false,
      clearChat: true,
      clearError: true,
      clearStatus: true,
    );
    try {
      final chat = await ref.read(clientProvider).chat(id);
      if (view != _view) return;
      state = state.copyWith(
        chat: chat,
        modelId: chat.models.firstOrNull ?? state.modelId,
        loading: false,
      );
    } catch (e) {
      if (view != _view) return;
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  /// Stops the reply on the server; what it wrote so far stays saved.
  Future<void> stop() async {
    final run = _run;
    if (run == null) return;
    run.stopped = true;
    await _stopTasks(run);
    run.finish();
  }

  Future<void> _stopTasks(_Run run) async {
    final client = ref.read(clientProvider);
    for (final id in run.taskIds) {
      try {
        await client.stopTask(id);
      } catch (_) {}
    }
  }

  /// False while there is nowhere to send: no model yet, a chat still
  /// loading, or a reply still running.
  bool get canSend =>
      state.modelId != null &&
      !state.loading &&
      !state.streaming &&
      !state.attachments.any((a) => a.uploading);

  /// Sends [text] after the visible conversation, or, with [editOf], as an
  /// edited version of that message: a new branch next to it, as on the web.
  /// The composer's photos and files go with it; an edit keeps the
  /// original's. Returns false if nothing was sent.
  Future<bool> send(String text, {ChatMessage? editOf}) async {
    final modelId = state.modelId;
    final files = editOf != null
        ? editOf.attachments
        : [
            for (final a in state.attachments)
              if (a.uploaded != null) a.uploaded!,
          ];
    if (!canSend || (text.trim().isEmpty && files.isEmpty) || modelId == null) {
      return false;
    }
    final chat =
        state.chat ??
        Chat(
          id: '',
          title: _titleFrom(
            text.trim().isNotEmpty ? text.trim() : files.first.name,
          ),
          messages: {},
          models: [modelId],
        );
    final user = ChatMessage(
      id: _uuid.v4(),
      role: 'user',
      content: text.trim(),
      parentId: editOf != null ? editOf.parentId : chat.currentId,
      extra: {
        'models': [modelId],
        if (files.isNotEmpty) 'files': [for (final f in files) f.toJson()],
      },
    );
    chat
      ..models = [modelId]
      ..append(user);
    if (editOf == null) state = state.copyWith(attachments: const []);
    await _reply(chat, user, modelId);
    return true;
  }

  /// A new answer to the same question, next to [reply] (Regenerate).
  Future<void> regenerate(ChatMessage reply) async {
    final chat = state.chat;
    final modelId = state.modelId;
    final user = chat?.messages[reply.parentId];
    if (state.streaming || chat == null || modelId == null || user == null) {
      return;
    }
    chat.currentId = user.id;
    await _reply(chat, user, modelId);
  }

  /// Shows the previous ([step] -1) or next (+1) version of [message], and
  /// the latest conversation under it. The choice is saved on the server.
  Future<void> switchBranch(ChatMessage message, int step) async {
    final chat = state.chat;
    if (chat == null || state.streaming) return;
    final siblings = chat.siblingsOf(message);
    final i = siblings.indexOf(message.id) + step;
    if (i < 0 || i >= siblings.length) return;
    chat.currentId = chat.latestUnder(siblings[i]);
    state = state.copyWith(chat: chat);
    try {
      await ref.read(clientProvider).saveChat(chat);
    } catch (_) {
      // Only the remembered branch is lost; the messages are all saved.
    }
  }

  /// Asks again for a reply that failed or never arrived (a new answer next
  /// to the failed one, like Regenerate on the web), or reloads the chat.
  Future<void> retry() async {
    final chat = state.chat;
    final modelId = state.modelId;
    state = state.copyWith(clearError: true);
    if (state.streaming || chat == null || modelId == null) {
      ref.invalidate(modelsProvider);
      return;
    }
    var tip = chat.messages[chat.currentId];
    if (tip != null &&
        tip.role == 'assistant' &&
        (tip.content.isEmpty || tip.error != null)) {
      tip = chat.messages[tip.parentId];
    }
    if (tip != null && tip.role == 'user') {
      chat.currentId = tip.id;
      await _reply(chat, tip, modelId);
    } else if (chat.id.isNotEmpty) {
      await open(chat.id);
    }
  }

  /// Has the server answer [user]: it saves both messages in the chat on the
  /// server, runs the model with the chat's tools and memory, and saves the
  /// reply. Live text comes over the socket; polling the chat is the backup.
  Future<void> _reply(Chat chat, ChatMessage user, String modelId) async {
    final client = ref.read(clientProvider);
    final socket = ref.read(chatSocketProvider);
    final reply = ChatMessage(
      id: _uuid.v4(),
      role: 'assistant',
      content: '',
      parentId: user.id,
      model: modelId,
    );
    chat.append(reply);
    final run = _run = _Run(reply);
    final view = _view;
    state = state.copyWith(
      chat: chat,
      streaming: true,
      clearError: true,
      clearStatus: true,
    );

    final sub = socket.events
        .where((e) => e['message_id'] == reply.id)
        .listen((e) => _onEvent(chat, run, e));
    try {
      final sessionId = await socket.ready() ?? 'nexus-app-${_uuid.v4()}';
      final models = await ref.read(modelsProvider.future);
      final started = await client.startTurn(
        model: modelId,
        chatId: chat.id.isEmpty ? null : chat.id,
        userMessage: user,
        replyId: reply.id,
        messages: [
          for (final m in chat.thread)
            if (m.id != reply.id) {'role': m.role, 'content': m.content},
        ],
        sessionId: sessionId,
        options: {
          ...requestOptions(
            models.where((m) => m.id == modelId).firstOrNull,
            await _optional(userSettingsProvider),
            await _optional(serverConfigProvider),
            overrides: state.features,
          ),
          'files': ?_documents(chat),
        },
      );
      chat.id = started.chatId;
      run.taskIds = started.taskIds;
      // Stop tapped while the request was on its way: stop it now.
      if (run.stopped) await _stopTasks(run);
      ref.invalidate(chatListProvider);
      unawaited(_poll(chat.id, run));
      await run.finished.future;
    } catch (e) {
      if (view == _view) state = state.copyWith(error: '$e');
    } finally {
      await sub.cancel();
      if (identical(_run, run)) _run = null;
    }
    if (view != _view) return; // the person moved on

    // The server's copy is the truth: it has the saved reply, its title,
    // sources and tool results.
    if (chat.id.isNotEmpty) {
      try {
        final saved = await client.chat(chat.id);
        if (view != _view) return;
        state = state.copyWith(chat: saved);
        ref.invalidate(chatListProvider);
      } catch (_) {}
    }
    final saved = state.chat?.messages[reply.id] ?? reply;
    state = state.copyWith(
      streaming: false,
      clearStatus: true,
      error:
          saved.error ??
          state.error ??
          (saved.content.isEmpty
              ? 'No reply came back. Tap Retry to ask again.'
              : null),
    );
  }

  void _onEvent(Chat chat, _Run run, Map<String, dynamic> event) {
    if (run.finished.isCompleted) return; // stopped, or the person moved on
    final reply = run.reply;
    final outer = event['data'];
    if (outer is! Map) return;
    final data = outer['data'];
    switch (outer['type']) {
      case 'response:completion' when data is Map:
        if (data['type'] == 'response.output_text.delta' &&
            data['delta'] is String) {
          reply.content += data['delta'] as String;
        }
        final item = data['item'];
        if (data['type'] == 'response.output_item.added' &&
            item is Map &&
            item['type'] == 'function_call') {
          state = state.copyWith(status: 'Using ${item['name']}…');
          return;
        }
      case 'chat:completion' when data is Map:
        final text = data['content'] is String
            ? data['content'] as String
            : ChatMessage.outputText(data['output']);
        if (text.isNotEmpty) reply.content = text;
        if (data['error'] != null) reply.extra['error'] = data['error'];
        if (data['done'] == true || data['error'] != null) run.finish();
      case 'chat:message:error' when data is Map:
        reply.extra['error'] = data['error'];
        run.finish();
      case 'chat:tasks:cancel':
        run.finish();
      case 'chat:title' when data is String:
        chat.title = data;
        ref.invalidate(chatListProvider);
      case 'status' when data is Map:
        state = data['done'] == true
            ? state.copyWith(clearStatus: true)
            : state.copyWith(status: data['description'] as String?);
        return;
      default:
        return;
    }
    state = state.copyWith();
  }

  /// Documents in the conversation for the server to search, as the web UI
  /// sends them; photos aren't included, the model sees those directly.
  List<Map<String, dynamic>>? _documents(Chat chat) {
    final seen = <String>{};
    final docs = [
      for (final m in chat.thread)
        for (final f in m.attachments)
          if (!f.isImage && seen.add(f.id ?? f.url ?? f.name)) f.toJson(),
    ];
    return docs.isEmpty ? null : docs;
  }

  /// Settings that only refine a message; a failure to read them must not
  /// stop it from being sent.
  Future<Map<String, dynamic>?> _optional(
    FutureProvider<Map<String, dynamic>> provider,
  ) async {
    try {
      return await ref.read(provider.future);
    } catch (_) {
      return null;
    }
  }

  /// Backup for a lost socket: checks the saved chat until the reply is done.
  Future<void> _poll(String chatId, _Run run) async {
    final client = ref.read(clientProvider);
    while (!run.finished.isCompleted) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (run.finished.isCompleted) return;
      try {
        final saved = (await client.chat(chatId)).messages[run.reply.id];
        if (saved != null && (saved.done || saved.error != null)) run.finish();
      } catch (_) {
        // Try again on the next tick; the reply keeps running on the server.
      }
    }
  }
}

bool _isRaster(String type) {
  final base = type.split(';').first.trim().toLowerCase();
  return base.startsWith('image/') && base != 'image/svg+xml';
}

/// A best guess from the file name when the picker doesn't say.
String? _mimeFromName(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return const {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'bmp': 'image/bmp',
    'svg': 'image/svg+xml',
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'md': 'text/markdown',
    'csv': 'text/csv',
    'json': 'application/json',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  }[ext];
}

String _titleFrom(String text) {
  final line = text.trim().split('\n').first;
  return line.length <= 50 ? line : '${line.substring(0, 50).trimRight()}…';
}

final chatControllerProvider = NotifierProvider<ChatController, ChatState>(
  ChatController.new,
);
