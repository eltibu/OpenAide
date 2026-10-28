import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderOrFamily;
import 'package:uuid/uuid.dart';

import '../../core/api/openwebui_client.dart' show ApiException;
import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../../core/models/model_info.dart';
import '../studio/listen.dart' show transcribe;
import '../voice/realtime_call.dart' show BridgeSubmission;
import '../workspace/prompts_api.dart' show fillSystemVariables;
import 'read_aloud.dart';
import 'reply_parts.dart';
import 'reply_notify.dart';
import 'request_options.dart';
import 'speech_prefs.dart';
import 'tool_approval.dart';

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

/// The model a new chat starts with, as the web UI picks it: your own
/// default (set with the star in the model list, or "Set as default" on
/// the web), else the server's default, else the first model.
String? pickDefaultModel(
  List<ModelInfo> models,
  Map<String, dynamic> settings,
  Map<String, dynamic> config,
) {
  bool known(String id) => models.any((m) => m.id == id);
  final ui = settings['ui'];
  final mine = ui is Map ? ui['models'] : null;
  for (final id in mine is List ? mine : const []) {
    if (id is String && known(id)) return id;
  }
  final server = '${config['default_models'] ?? ''}'.split(',');
  for (final id in server.map((s) => s.trim())) {
    if (id.isNotEmpty && known(id)) return id;
  }
  return models.firstOrNull?.id;
}

final defaultModelProvider = FutureProvider<String?>((ref) async {
  final models = await ref.watch(modelsProvider.future);
  Future<Map<String, dynamic>> optional(
    FutureProvider<Map<String, dynamic>> p,
  ) async {
    try {
      return await ref.watch(p.future);
    } catch (_) {
      return const {};
    }
  }

  return pickDefaultModel(
    models,
    await optional(userSettingsProvider),
    await optional(serverConfigProvider),
  );
});

/// The tools and skills this person may switch on in a chat.
final toolsProvider = FutureProvider<List<Pickable>>((ref) async {
  final res = await ref.watch(clientProvider).send('GET', '/api/v1/tools/');
  return [
    for (final t in (res as List? ?? const []).whereType<Map>())
      Pickable.fromJson(t.cast<String, dynamic>()),
  ];
});
final skillsProvider = FutureProvider<List<Pickable>>((ref) async {
  final res = await ref.watch(clientProvider).send('GET', '/api/v1/skills/');
  return [
    for (final t in (res as List? ?? const []).whereType<Map>())
      if (t['is_active'] != false) Pickable.fromJson(t.cast<String, dynamic>()),
  ];
});

/// How many pages of the main chat list to show (60 chats each).
class ChatPages extends Notifier<int> {
  @override
  int build() {
    ref.watch(clientProvider);
    return 1;
  }

  void more() => state++;
}

final chatPagesProvider = NotifierProvider<ChatPages, int>(ChatPages.new);

/// The main list: chats that are neither pinned nor in a folder, newest
/// first, as in the web UI's sidebar.
final chatListProvider = FutureProvider<List<ChatSummary>>((ref) async {
  final client = ref.watch(clientProvider);
  final pages = ref.watch(chatPagesProvider);
  final all = <ChatSummary>[];
  for (var page = 1; page <= pages; page++) {
    final batch = await client.chats(page: page);
    all.addAll(batch);
    if (batch.length < chatPageSize) break;
  }
  return all;
});

const chatPageSize = 60;

final pinnedChatsProvider = FutureProvider<List<ChatSummary>>(
  (ref) => ref.watch(clientProvider).pinnedChats(),
);

final foldersProvider = FutureProvider<List<Folder>>(
  (ref) => ref.watch(clientProvider).folders(),
);

/// A folder's chats: the first `pages` pages of ten.
final folderChatsProvider =
    FutureProvider.family<List<ChatSummary>, (String, int)>((ref, arg) async {
      final client = ref.watch(clientProvider);
      final (folderId, pages) = arg;
      final all = <ChatSummary>[];
      for (var page = 1; page <= pages; page++) {
        final batch = await client.folderChats(folderId, page: page);
        all.addAll(batch);
        if (batch.length < folderPageSize) break;
      }
      return all;
    });

const folderPageSize = 10;

final chatSearchProvider = FutureProvider.family<List<ChatSummary>, String>(
  (ref, text) => ref.watch(clientProvider).searchChats(text),
);

/// Reloads every chat list after a chat or folder changed.
void refreshChatLists(void Function(ProviderOrFamily) invalidate) {
  invalidate(chatListProvider);
  invalidate(pinnedChatsProvider);
  invalidate(foldersProvider);
  invalidate(folderChatsProvider);
  invalidate(chatSearchProvider);
}

class ChatState {
  const ChatState({
    this.chat,
    this.modelId,
    this.streaming = false,
    this.loading = false,
    this.error,
    this.status,
    this.features = const {},
    this.toolIds,
    this.skillIds,
    this.terminalId,
    this.attachments = const [],
    this.temporary = false,
    this.queued = const [],
    this.compareIds = const [],
    this.params = const {},
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

  /// Tools and skills switched on in this chat; null until the person picks
  /// (then the model's own tools apply, and no extra skills).
  final Set<String>? toolIds;
  final Set<String>? skillIds;

  /// The terminal picked for this chat: null is the model's, '' is none.
  final String? terminalId;

  /// Photos and files waiting in the composer for the next message.
  final List<PendingAttachment> attachments;

  /// A temporary chat, as on the web: answered by the server but never
  /// saved, so it isn't in the chat list and is gone once you leave it.
  final bool temporary;

  /// Messages written while a reply was running, sent together when it's
  /// done, as the web's message queue does.
  final List<String> queued;

  /// More models answering each message next to [modelId], to compare.
  final List<String> compareIds;

  /// This chat's own system prompt and model settings (Controls on the
  /// web), saved with the chat; they win over Settings > General.
  final Map<String, dynamic> params;

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
    Set<String>? toolIds,
    Set<String>? skillIds,
    String? terminalId,
    List<PendingAttachment>? attachments,
    bool? temporary,
    List<String>? queued,
    List<String>? compareIds,
    Map<String, dynamic>? params,
  }) => ChatState(
    chat: clearChat ? null : chat ?? this.chat,
    modelId: modelId ?? this.modelId,
    streaming: streaming ?? this.streaming,
    loading: loading ?? this.loading,
    error: clearError ? null : error ?? this.error,
    status: clearStatus ? null : status ?? this.status,
    features: features ?? this.features,
    toolIds: toolIds ?? this.toolIds,
    skillIds: skillIds ?? this.skillIds,
    terminalId: terminalId ?? this.terminalId,
    attachments: attachments ?? this.attachments,
    temporary: temporary ?? this.temporary,
    queued: queued ?? this.queued,
    compareIds: compareIds ?? this.compareIds,
    params: params ?? this.params,
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

  /// How much of the reply has been handed to read aloud.
  int spoken = 0;

  /// The other models' replies to the same message, when comparing.
  List<_Run> also = const [];

  void finish() {
    if (!finished.isCompleted) finished.complete();
  }

  /// Ends this reply and the other models' with it.
  void cancel() {
    finish();
    for (final r in also) {
      r.finish();
    }
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
      _run?.cancel();
    });
    // Connect early so the first reply streams live, and pick up what the
    // server adds after a reply is done (follow-up suggestions).
    Future.microtask(() {
      try {
        final sub = ref.read(chatSocketProvider).events.listen(_afterReply);
        ref.onDispose(sub.cancel);
      } catch (_) {}
    });
    // Settings > Interface can start every new chat as a temporary one.
    final view = _view;
    unawaited(
      _optional(userSettingsProvider).then((s) {
        final fresh = state.chat == null && state.messages.isEmpty;
        if (view == _view && fresh && _uiFlag(s, 'temporaryChatByDefault')) {
          state = state.copyWith(temporary: true);
        }
      }),
    );
    return const ChatState();
  }

  void selectModel(String id) => state = state.copyWith(modelId: id);

  void setFeature(String id, bool on) =>
      state = state.copyWith(features: {...state.features, id: on});

  /// Switches a tool for this chat, starting from the model's own tools.
  void setTool(String id, bool on) {
    final model = ref
        .read(modelsProvider)
        .value
        ?.where((m) => m.id == state.modelId)
        .firstOrNull;
    final now = {...?state.toolIds ?? model?.toolIds.toSet()};
    on ? now.add(id) : now.remove(id);
    state = state.copyWith(toolIds: now);
  }

  void setSkill(String id, bool on) {
    final now = {...?state.skillIds};
    on ? now.add(id) : now.remove(id);
    state = state.copyWith(skillIds: now);
  }

  /// '' switches the terminal off for this chat.
  void setTerminal(String id) => state = state.copyWith(terminalId: id);

  /// A new chat; temporary unless asked otherwise when Settings > Interface
  /// says to start chats that way.
  void newChat({bool? temporary}) {
    temporary ??= _uiFlag(
      ref.read(userSettingsProvider).value,
      'temporaryChatByDefault',
    );
    _view++;
    _run?.cancel();
    unawaited(ref.read(readAloudProvider).stop());
    state = ChatState(
      modelId: state.modelId,
      attachments: state.attachments,
      temporary: temporary,
      compareIds: state.compareIds,
    );
  }

  /// Keeps a temporary chat: saves it as a normal chat and opens that.
  Future<void> saveTemporary() async {
    final last = state.messages.lastOrNull;
    if (!state.temporary || last == null) return;
    final chat = state.chat!;
    if (chat.title.isEmpty || chat.title == 'New chat') {
      final first = state.messages.first.content.trim().split('\n').first;
      chat.title = first.length > 50 ? '${first.substring(0, 50)}…' : first;
    }
    await fork(last, title: chat.title);
  }

  /// Renames a chat on the server (and on screen, if it's open).
  Future<void> renameChat(String id, String title) async {
    await ref.read(clientProvider).renameChat(id, title);
    final chat = state.chat;
    if (chat != null && chat.id == id) {
      chat.title = title;
      state = state.copyWith(chat: chat);
    }
    refreshChatLists(ref.invalidate);
  }

  Future<void> togglePin(String id) async {
    await ref.read(clientProvider).togglePin(id);
    refreshChatLists(ref.invalidate);
  }

  Future<void> moveChat(String id, String? folderId) async {
    await ref.read(clientProvider).moveChat(id, folderId);
    refreshChatLists(ref.invalidate);
  }

  /// Archives a chat; it leaves the lists and the screen, as on the web.
  Future<void> archiveChat(String id) async {
    await ref.read(clientProvider).toggleArchive(id);
    if (state.chat?.id == id) newChat();
    refreshChatLists(ref.invalidate);
  }

  Future<void> deleteChat(String id) async {
    await ref.read(clientProvider).deleteChat(id);
    if (state.chat?.id == id) newChat();
    refreshChatLists(ref.invalidate);
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
        uploaded: Attachment.uploaded(
          uploaded,
          size: bytes.length,
          // Settings > Interface > Using entire document.
          fullContext:
              !isImage &&
              (ref.read(userSettingsProvider).value?['ui']
                      as Map?)?['defaultUploadContext'] ==
                  'full',
        ),
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
      // Say why, not just a red mark on the tile.
      error: done.error == null ? null : "Couldn't attach $name: ${done.error}",
    );
  }

  /// Sends a recorded voice note: the recording goes with the message so it
  /// can be played back, and the server's transcription is the text the
  /// model reads. If no words come back the note stays in the composer.
  Future<void> sendVoiceNote(List<int> wav) async {
    final key = _uuid.v4();
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '-');
    final name = 'Voice note $stamp.wav';
    state = state.copyWith(
      attachments: [
        ...state.attachments,
        PendingAttachment(key: key, name: name, isImage: false),
      ],
    );
    final client = ref.read(clientProvider);
    PendingAttachment done;
    var text = '';
    try {
      final upload = client.uploadFile(
        wav,
        name,
        contentType: 'audio/wav',
        // The app sends the words itself; the server needn't index them.
        process: false,
      );
      final words = transcribe(
        client,
        wav,
        name,
        language: speechLanguage(await _optional(userSettingsProvider)),
      );
      final uploaded = await upload;
      done = PendingAttachment(
        key: key,
        name: name,
        isImage: false,
        uploaded: Attachment.uploaded(uploaded, size: wav.length),
      );
      text = await words;
    } catch (e) {
      done = PendingAttachment(
        key: key,
        name: name,
        isImage: false,
        error: '$e',
      );
    }
    if (!state.attachments.any((a) => a.key == key)) return;
    state = state.copyWith(
      attachments: [for (final a in state.attachments) a.key == key ? done : a],
      error: done.error != null
          ? "Couldn't send the voice note: ${done.error}"
          : text.isEmpty
          ? 'No words came through in the voice note. It is attached; '
                'type a message to send it, or record again.'
          : null,
    );
    if (done.error != null || text.isEmpty) return;
    for (var i = 0; i < 100 && !canSend; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await send(text);
  }

  /// Adds something already on the server to the next message, as the web
  /// UI's + menu does: a note, a knowledge base or a past chat, by its id;
  /// the server reads it when the message is answered.
  void attachReference(Map<String, dynamic> entry) {
    if (state.attachments.any(
      (a) => a.uploaded?.id == entry['id'] && a.uploaded?.type == entry['type'],
    )) {
      return;
    }
    state = state.copyWith(
      attachments: [
        ...state.attachments,
        PendingAttachment(
          key: _uuid.v4(),
          name: '${entry['name']}',
          isImage: false,
          uploaded: Attachment.fromJson(entry),
        ),
      ],
    );
  }

  /// Reads a web page on the server and adds it to the next message.
  Future<void> attachWebpage(String url) async {
    final key = _uuid.v4();
    state = state.copyWith(
      attachments: [
        ...state.attachments,
        PendingAttachment(key: key, name: url, isImage: false),
      ],
    );
    PendingAttachment done;
    try {
      final res = await ref
          .read(clientProvider)
          .send('POST', '/api/v1/retrieval/process/url', body: {'url': url});
      final r = (res as Map).cast<String, dynamic>();
      final file = r['file'];
      final name = '${r['name'] ?? url}';
      final Map<String, dynamic> entry;
      if (file is Map && file['id'] is String) {
        final meta = (file['meta'] as Map?) ?? const {};
        entry = {
          'type': r['type'] == 'image' ? 'image' : 'file',
          'file': file,
          'id': file['id'],
          'url': file['id'],
          'name': name,
          'collection_name':
              r['collection_name'] ?? meta['collection_name'] ?? '',
          'status': 'uploaded',
          'content_type': ?meta['content_type'],
          'size': ?meta['size'],
          'error': '',
        };
      } else {
        entry = {
          'type': 'text',
          'name': name,
          'url': url,
          'collection_name': r['collection_name'] ?? '',
          'status': 'uploaded',
          'context': 'full',
          'file': {
            'data': {'content': r['content'] ?? ''},
            'meta': {'name': name, 'source': r['url'] ?? url},
          },
          'error': '',
        };
      }
      done = PendingAttachment(
        key: key,
        name: name,
        isImage: false,
        uploaded: Attachment.fromJson(entry),
      );
    } catch (e) {
      done = PendingAttachment(
        key: key,
        name: url,
        isImage: false,
        error: '$e',
      );
    }
    if (!state.attachments.any((a) => a.key == key)) return;
    state = state.copyWith(
      attachments: [for (final a in state.attachments) a.key == key ? done : a],
      error: done.error == null ? null : "Couldn't read $url: ${done.error}",
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
    _run?.cancel();
    unawaited(ref.read(readAloudProvider).stop());
    state = state.copyWith(
      loading: true,
      streaming: false,
      clearChat: true,
      clearError: true,
      clearStatus: true,
      temporary: false,
      queued: const [],
      params: const {},
    );
    try {
      final chat = await ref.read(clientProvider).chat(id);
      if (view != _view) return;
      state = state.copyWith(
        chat: chat,
        modelId: chat.models.firstOrNull ?? state.modelId,
        compareIds: chat.models.skip(1).toList(),
        params: {
          for (final e in ((chat.extra['params'] as Map?) ?? const {}).entries)
            if (e.value != null) '${e.key}': e.value,
        },
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
    unawaited(ref.read(readAloudProvider).stop());
    await _stopTasks(run);
    run.cancel();
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
        'models': [modelId, ...state.compareIds],
        if (files.isNotEmpty) 'files': [for (final f in files) f.toJson()],
      },
    );
    chat
      ..models = [modelId, ...state.compareIds]
      ..append(user);
    if (editOf == null) state = state.copyWith(attachments: const []);
    await _reply(chat, user, modelId, also: state.compareIds);
    return true;
  }

  /// Sets one of this chat's controls ([value] null goes back to the
  /// default) and saves them with the chat, as the web's Controls panel does.
  Future<void> setParam(String key, Object? value) async {
    final params = {...state.params};
    if (value == null || (value is String && value.trim().isEmpty)) {
      params.remove(key);
    } else {
      params[key] = value;
    }
    state = state.copyWith(params: params);
    final chat = state.chat;
    if (chat == null || chat.id.isEmpty) return;
    chat.extra['params'] = params;
    try {
      // The server merges what it gets, so a default goes back as null.
      await ref.read(clientProvider).saveChatParams(chat.id, {
        key: params[key],
      });
    } catch (e) {
      state = state.copyWith(error: "Couldn't save the chat's controls: $e");
    }
  }

  /// Has [ids] answer too, next to the chosen model (the web's "+" beside
  /// the model name).
  void setCompare(List<String> ids) => state = state.copyWith(
    compareIds: [
      for (final id in ids.toSet())
        if (id != state.modelId) id,
    ],
  );

  /// The replies to [user] from each model it was sent to, newest version
  /// of each, in the order the models were picked.
  List<ChatMessage> answersTo(ChatMessage user) {
    final chat = state.chat;
    if (chat == null) return const [];
    final byModel = <Object, ChatMessage>{};
    for (final id in user.childrenIds) {
      final m = chat.messages[id];
      if (m == null) continue;
      byModel[m.extra['modelIdx'] ?? m.model ?? id] = m;
    }
    return byModel.values.toList();
  }

  /// Shows [answer] (another model's reply to the same message) and the
  /// conversation under it.
  Future<void> showAnswer(ChatMessage answer) async {
    final chat = state.chat;
    if (chat == null || state.streaming) return;
    chat.currentId = chat.latestUnder(answer.id);
    state = state.copyWith(chat: chat);
    if (chat.id.isEmpty) return;
    try {
      await ref.read(clientProvider).saveChat(chat);
    } catch (_) {}
  }

  /// One answer made from every model's reply to the same message (Merge
  /// Responses on the web), shown above them and saved in the chat.
  Future<void> merge(ChatMessage reply) async {
    final chat = state.chat;
    final user = chat?.messages[reply.parentId];
    if (chat == null || user == null || state.streaming) return;
    final answers = answersTo(user);
    if (answers.length < 2) return;
    final merged = <String, dynamic>{'status': true, 'content': ''};
    reply.extra['merged'] = merged;
    state = state.copyWith(chat: chat, streaming: true, clearError: true);
    try {
      await for (final text
          in ref
              .read(clientProvider)
              .streamMerge(
                model: reply.model ?? state.modelId ?? '',
                prompt: user.content,
                responses: [for (final a in answers) a.content],
              )) {
        if (merged['content'] == '' && text == '\n') continue;
        merged['content'] = '${merged['content']}$text';
        state = state.copyWith(chat: chat);
      }
      if (chat.id.isNotEmpty) await ref.read(clientProvider).saveChat(chat);
    } catch (e) {
      if ('${merged['content']}'.isEmpty) reply.extra.remove('merged');
      state = state.copyWith(error: "Couldn't merge the answers: $e");
    } finally {
      state = state.copyWith(chat: chat, streaming: false);
    }
  }

  /// Holds [text] until the running reply is done, then sends it.
  void queue(String text) {
    if (text.trim().isEmpty) return;
    state = state.copyWith(queued: [...state.queued, text.trim()]);
  }

  /// Takes queued message [i] out of the queue and returns it.
  String unqueue(int i) {
    final list = [...state.queued];
    final text = list.removeAt(i);
    state = state.copyWith(queued: list);
    return text;
  }

  /// Sends what's queued as one message, once nothing is running.
  Future<void> sendQueued() async {
    if (state.queued.isEmpty) return;
    final text = state.queued.join('\n\n');
    if (state.streaming) {
      state = state.copyWith(queued: const []);
      await steer(text);
      return;
    }
    if (!canSend) return;
    state = state.copyWith(queued: const []);
    await send(text);
  }

  /// Steers a running reply: stops it where it is (what it wrote stays in
  /// the chat) and sends [text] right away, so the next answer follows it.
  Future<bool> steer(String text) async {
    if (state.streaming) {
      await stop();
      final until = DateTime.now().add(const Duration(seconds: 15));
      while (state.streaming && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      state = state.copyWith(clearError: true);
    }
    return send(text);
  }

  /// Starts a new chat with this chat's conversation up to [at]; the
  /// original stays as it is. Opens the new one.
  Future<void> fork(ChatMessage at, {String? title}) async {
    final chat = state.chat;
    if (chat == null || state.streaming) return;
    final path = chat.thread;
    final end = path.indexWhere((m) => m.id == at.id);
    if (end < 0) return;
    final kept = path.sublist(0, end + 1);
    final copy = Chat(
      id: '',
      title: title ?? '${chat.title} (fork)',
      messages: {},
      models: [...chat.models],
      extra: {
        for (final e in chat.extra.entries)
          if (e.key == 'params' || e.key == 'system' || e.key == 'files')
            e.key: e.value,
      },
    );
    for (var i = 0; i < kept.length; i++) {
      final m = ChatMessage.fromJson(
        jsonDecode(jsonEncode(kept[i].toJson())) as Map<String, dynamic>,
      );
      m.childrenIds
        ..clear()
        ..addAll([if (i + 1 < kept.length) kept[i + 1].id]);
      copy.messages[m.id] = m;
    }
    copy.currentId = at.id;
    try {
      final made = await ref.read(clientProvider).createChat(copy);
      refreshChatLists(ref.invalidate);
      await open(made.id);
    } catch (e) {
      state = state.copyWith(error: "Couldn't fork the chat: $e");
    }
  }

  /// Has the server sum up the older part of this chat so it fits the
  /// model again (/compact). Returns why nothing changed, or null when it
  /// was compacted (then the chat is reloaded).
  Future<String?> compact() async {
    final chat = state.chat;
    if (chat == null || chat.id.isEmpty) return 'No chat to compact';
    if (state.streaming) {
      return 'Wait for the current response to finish before compacting.';
    }
    final Object? res;
    try {
      res = await ref
          .read(clientProvider)
          .send(
            'POST',
            '/api/v1/chats/${chat.id}/compact',
            body: {if (state.modelId != null) 'model': state.modelId},
          );
    } on ApiException catch (e) {
      // Still finishing (titles, follow-ups): the server says to wait.
      if (e.statusCode == 409) return e.message;
      rethrow;
    }
    final out = res is Map ? res : const {};
    if (out['compacted'] == true) {
      await open(chat.id);
      return null;
    }
    return switch (out['reason']) {
      'too_short' => 'Chat is too short to compact',
      'empty' => 'No chat to compact',
      'disabled' => 'Context compaction is disabled',
      _ => 'Nothing to compact',
    };
  }

  /// How full the model's context is for this chat, as the server counts
  /// it ({tokens, threshold, percent}); null when compaction is off.
  Future<Map<String, dynamic>?> contextUsage() async {
    final chat = state.chat;
    if (chat == null || chat.id.isEmpty) return null;
    final res = await ref
        .read(clientProvider)
        .send('GET', '/api/v1/chats/${chat.id}');
    final usage = res is Map ? res['context_usage'] : null;
    return usage is Map ? usage.cast<String, dynamic>() : null;
  }

  /// A new answer to the same question, next to [reply] (Regenerate). A
  /// [hint] ("Add details", "More concise", or the person's own words) asks
  /// for a different answer than the old one, as the web's regenerate menu
  /// does.
  Future<void> regenerate(ChatMessage reply, {String? hint}) async {
    final chat = state.chat;
    final modelId = state.modelId;
    final user = chat?.messages[reply.parentId];
    if (state.streaming || chat == null || modelId == null || user == null) {
      return;
    }
    chat.currentId = user.id;
    final h = hint?.trim();
    await _reply(
      chat,
      user,
      reply.model ?? modelId,
      redoOf: h == null || h.isEmpty ? null : reply,
      hint: h == null || h.isEmpty ? null : h,
    );
  }

  /// Has the model keep writing [reply] where it stopped (Continue
  /// Response).
  Future<void> continueReply(ChatMessage reply) async {
    final chat = state.chat;
    final modelId = reply.model ?? state.modelId;
    final user = chat?.messages[reply.parentId];
    if (state.streaming || chat == null || modelId == null || user == null) {
      return;
    }
    await _reply(chat, user, modelId, continuing: reply);
  }

  /// Changes a reply's text in place, or with [asCopy] keeps the original
  /// and adds the edited text as another version next to it.
  Future<void> editReply(
    ChatMessage reply,
    String text, {
    bool asCopy = false,
  }) async {
    final chat = state.chat;
    if (chat == null || chat.id.isEmpty || state.streaming) return;
    final client = ref.read(clientProvider);
    try {
      if (!asCopy) {
        reply.content = text;
        reply.extra.remove('output');
        state = state.copyWith(chat: chat);
        await client.saveMessageText(chat.id, reply.id, text);
        return;
      }
      final copy =
          ChatMessage.fromJson({
              ...reply.toJson(),
              'id': _uuid.v4(),
              'content': text,
              'childrenIds': <String>[],
              'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            })
            ..extra.remove('output')
            ..extra.remove('annotation')
            ..extra.remove('feedbackId')
            ..extra.remove('files');
      chat.append(copy);
      state = state.copyWith(chat: chat);
      await client.saveChat(chat);
    } catch (e) {
      state = state.copyWith(error: "Couldn't save the change: $e");
    }
  }

  /// Deletes [message] and the answers right under it, as the web does.
  Future<void> deleteMessage(ChatMessage message) async {
    final chat = state.chat;
    if (chat == null || chat.id.isEmpty || state.streaming) return;
    try {
      final saved = await ref
          .read(clientProvider)
          .deleteMessage(chat.id, message.id);
      state = state.copyWith(chat: saved);
      refreshChatLists(ref.invalidate);
    } catch (e) {
      state = state.copyWith(error: "Couldn't delete the message: $e");
    }
  }

  /// Thumbs up (1) or down (-1) on a reply, with an optional reason and
  /// comment, saved on the message and in Admin > Evaluations like the web.
  /// The same rating again takes it back.
  Future<void> rate(
    ChatMessage reply,
    int rating, {
    String? reason,
    String? comment,
  }) async {
    final chat = state.chat;
    if (chat == null || chat.id.isEmpty) return;
    final before = (reply.extra['annotation'] as Map?)?.cast<String, dynamic>();
    final undo =
        reason == null && comment == null && before?['rating'] == rating;
    final annotation = <String, dynamic>{...?before};
    annotation['rating'] = undo ? null : rating;
    if (before?['rating'] != rating) {
      annotation
        ..['reason'] = null
        ..['comment'] = null;
    }
    if (reason != null) annotation['reason'] = reason;
    if (comment != null) annotation['comment'] = comment;
    reply.extra['annotation'] = annotation;
    state = state.copyWith(chat: chat);
    final client = ref.read(clientProvider);
    try {
      if (!undo) {
        final siblings = chat.siblingsOf(reply).where((id) => id != reply.id);
        final id = await client.saveFeedback({
          'type': 'rating',
          'data': {
            ...annotation,
            'model_id': reply.model,
            if (siblings.isNotEmpty)
              'sibling_model_ids': [
                for (final s in siblings) chat.messages[s]?.model,
              ],
          },
          'meta': {
            'model_id': reply.model,
            'message_id': reply.id,
            'message_index':
                chat.thread.indexWhere((m) => m.id == reply.id) + 1,
            'chat_id': chat.id,
          },
          'snapshot': {
            'chat': {'id': chat.id, 'chat': chat.toServerBody()},
          },
        }, id: reply.extra['feedbackId'] as String?);
        if (id != null) reply.extra['feedbackId'] = id;
      }
      await client.saveChat(chat);
    } catch (e) {
      state = state.copyWith(error: "Couldn't save the rating: $e");
    }
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
  Future<void> _reply(
    Chat chat,
    ChatMessage user,
    String modelId, {
    Completer<({String replyId, List<String> taskIds})>? started,
    ChatMessage? continuing,
    ChatMessage? redoOf,
    String? hint,
    List<String> also = const [],
  }) async {
    final client = ref.read(clientProvider);
    final socket = ref.read(chatSocketProvider);
    if (continuing != null || redoOf != null) also = const [];
    // What the model reads: the conversation up to the new reply; when
    // continuing, the reply so far; with a hint, the old answer too.
    final history = [
      ...chat.thread,
      if (hint != null && redoOf != null) redoOf,
    ];
    final ChatMessage reply;
    if (continuing != null) {
      reply = continuing..extra.remove('done');
      chat.currentId = reply.id;
    } else {
      reply = ChatMessage(
        id: _uuid.v4(),
        role: 'assistant',
        content: '',
        parentId: user.id,
        model: modelId,
        extra: {if (also.isNotEmpty) 'modelIdx': 0},
      );
      chat.append(reply);
    }
    // Comparing: the other models' replies sit next to it, as on the web.
    final others = [
      for (final (i, id) in also.indexed)
        ChatMessage(
          id: _uuid.v4(),
          role: 'assistant',
          content: '',
          parentId: user.id,
          model: id,
          extra: {'modelIdx': i + 1},
        ),
    ];
    for (final o in others) {
      chat.append(o);
    }
    chat.currentId = reply.id;
    unawaited(ref.read(readAloudProvider).stop());
    final run = _run = _Run(reply);
    run.also = [for (final o in others) _Run(o)];
    final runs = {
      for (final r in [run, ...run.also]) r.reply.id: r,
    };
    final view = _view;
    state = state.copyWith(
      chat: chat,
      streaming: true,
      clearError: true,
      clearStatus: true,
    );

    final sub = socket.events
        .where((e) => runs.containsKey(e['message_id']))
        .listen((e) => _onEvent(chat, runs[e['message_id']]!, e));
    try {
      final live = await socket.ready();
      // A temporary chat's reply only comes over the live connection.
      if (state.temporary && live == null) {
        throw Exception(
          "Temporary chats need a live connection to the server, and it isn't "
          'connected right now. Try again in a moment.',
        );
      }
      final sessionId = live ?? 'nexus-app-${_uuid.v4()}';
      final temporary = state.temporary;
      final models = await ref.read(modelsProvider.future);
      final settings = await _optional(userSettingsProvider);
      final chatParams = state.params;
      final system =
          '${chatParams['system'] ?? (settings?['ui'] as Map?)?['system'] ?? ''}'
              .trim();
      ref
          .read(readAloudProvider)
          .useVoice(
            speechVoice(
              settings,
              await _optional(serverConfigProvider),
              models.where((m) => m.id == modelId).firstOrNull?.meta,
            ),
            rate: speechRate(settings),
          );
      final me = ref.read(sessionProvider).value?.user;
      final turn = await client.startTurn(
        model: modelId,
        chatId: temporary
            ? 'temporary:$sessionId'
            : chat.id.isEmpty
            ? null
            : chat.id,
        userMessage: user,
        replyId: reply.id,
        messages: [
          // The person's own system prompt (Settings > General), filled in
          // as the web does.
          if (system.isNotEmpty)
            {
              'role': 'system',
              'content': fillSystemVariables(
                system,
                userName: me?['name'] as String?,
                userEmail: me?['email'] as String?,
              ),
            },
          for (final m in history)
            if (m.id != reply.id || continuing != null)
              {'role': m.role, 'content': m.content},
        ],
        sessionId: sessionId,
        options: {
          ..._withVoice(
            requestOptions(
              models.where((m) => m.id == modelId).firstOrNull,
              settings,
              await _optional(serverConfigProvider),
              overrides: state.features,
              toolIds: state.toolIds,
              skillIds: state.skillIds,
              terminalId: state.terminalId,
              chatParams: chatParams,
            ),
          ),
          'files': ?_documents(chat),
          if (continuing != null) 'assistant_message_id': reply.id,
          'regeneration_prompt': ?hint,
          if (hint != null && redoOf != null)
            'regeneration_message_id': redoOf.id,
          if (others.isNotEmpty)
            'message_ids': [
              for (final r in runs.values)
                {'model_id': r.reply.model, 'message_id': r.reply.id},
            ],
        },
      );
      // A temporary chat keeps no id: nothing of it is on the server.
      if (!temporary) {
        final isNew = chat.id.isEmpty;
        chat.id = turn.chatId;
        // Controls set before the first message are saved with the new
        // chat, as the web does.
        if (isNew && chatParams.isNotEmpty) {
          chat.extra['params'] = chatParams;
          unawaited(
            client.saveChatParams(chat.id, chatParams).catchError((_) {}),
          );
        }
      }
      run.taskIds = turn.taskIds;
      started?.complete((replyId: reply.id, taskIds: turn.taskIds));
      // Stop tapped while the request was on its way: stop it now.
      if (run.stopped) await _stopTasks(run);
      if (!temporary) {
        refreshChatLists(ref.invalidate);
        for (final r in runs.values) {
          unawaited(_poll(chat.id, r));
        }
      }
      await Future.wait([for (final r in runs.values) r.finished.future]);
    } catch (e) {
      if (started != null && !started.isCompleted) started.completeError(e);
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
        refreshChatLists(ref.invalidate);
      } catch (_) {}
    }
    final saved = state.chat?.messages[reply.id] ?? reply;
    if (!run.stopped) {
      _speak(
        run,
        run.spoken == 0 || saved.content.startsWith(reply.content)
            ? saved.content
            : reply.content,
        done: true,
      );
      unawaited(
        _afterDone(saved.content, chat.id, state.chat?.title ?? chat.title),
      );
    }
    state = state.copyWith(
      streaming: false,
      clearStatus: true,
      error:
          saved.error ??
          state.error ??
          (saved.content.isEmpty && pendingCall(saved) == null
              ? 'No reply came back. Tap Retry to ask again.'
              : null),
    );
    // Then what was queued meanwhile; a stopped, failed or paused reply
    // leaves the queue for the person to send.
    if (!run.stopped && state.error == null && pendingCall(saved) == null) {
      unawaited(sendQueued());
    }
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
        // Thinking, tool calls and text, in order, as they happen.
        reply.extra['output'] = applyOutputEvent(_liveOutput(reply), data);
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
        if (data['output'] is List) {
          reply.extra['output'] = [
            for (final item in (data['output'] as List).whereType<Map>())
              item.cast<String, dynamic>(),
          ];
        }
        if (data['error'] != null) reply.extra['error'] = data['error'];
        if (data['done'] == true || data['error'] != null) run.finish();
        // Paused for the person: a tool to allow or questions to answer.
        if (pendingCall(reply) != null) run.finish();
      case 'chat:message:error' when data is Map:
        reply.extra['error'] = data['error'];
        run.finish();
      case 'files' || 'chat:message:files' when data is Map:
        // Pictures the reply made (image generation, tools) show as they come.
        final files = (data['files'] as List? ?? const []).whereType<Map>();
        if (files.isEmpty) return;
        final kept = (reply.extra['files'] as List? ?? const []).toList();
        reply.extra['files'] = [...kept, ...files];
      case 'embeds' when data is Map:
        // A tool's player or chart, shown as it arrives.
        final embeds = (data['embeds'] as List? ?? const [])
            .whereType<String>();
        if (embeds.isEmpty) return;
        final kept = data['replace'] == true
            ? const []
            : (reply.extra['embeds'] as List? ?? const []);
        reply.extra['embeds'] = [...embeds, ...kept];
      case 'chat:tasks:cancel':
        run.finish();
      case 'chat:title' when data is String:
        chat.title = data;
        refreshChatLists(ref.invalidate);
      case 'status' when data is Map:
        // Kept on the reply as the web does, shown as its task steps.
        if (data['hidden'] != true && data['description'] != null) {
          final history = (reply.extra['statusHistory'] as List? ?? const [])
              .toList();
          final last = history.lastOrNull;
          if (last is Map &&
              last['description'] == data['description'] &&
              last['done'] != true) {
            history.last = data;
          } else {
            history.add(data);
          }
          reply.extra['statusHistory'] = history;
        }
        state = data['done'] == true
            ? state.copyWith(clearStatus: true)
            : state.copyWith(status: data['description'] as String?);
        return;
      default:
        return;
    }
    _speak(run, reply.content);
    state = state.copyWith();
  }

  /// Answers a reply that paused for the person (Allow/Deny on a tool, or
  /// the model's questions) and follows it as the server carries on.
  Future<void> resolveTool(
    ChatMessage reply,
    String callId,
    String action, {
    Map<String, dynamic>? answers,
  }) async {
    final chat = state.chat;
    if (chat == null || chat.id.isEmpty || state.streaming) return;
    final client = ref.read(clientProvider);
    final socket = ref.read(chatSocketProvider);
    // Mark the call as answered here, so the card goes and an early update
    // still showing it as waiting doesn't end the run.
    final output = reply.extra['output'];
    if (output is List) {
      reply.extra['output'] = [
        for (final item in output)
          if (item is Map && (item['call_id'] ?? item['id']) == callId)
            {...item, 'status': action == 'reject' ? 'rejected' : 'in_progress'}
          else
            item,
      ];
    }
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
      await socket.ready();
      run.taskIds = await client.resolveToolCall(
        chat.id,
        reply.id,
        callId,
        action,
        answers: answers,
      );
      if (run.stopped) await _stopTasks(run);
      if (run.taskIds.isNotEmpty) {
        unawaited(_poll(chat.id, run));
        await run.finished.future;
      }
    } catch (e) {
      if (view == _view) state = state.copyWith(error: '$e');
    } finally {
      run.finish();
      await sub.cancel();
      if (identical(_run, run)) _run = null;
    }
    if (view != _view) return;
    try {
      final saved = await client.chat(chat.id);
      if (view != _view) return;
      state = state.copyWith(chat: saved);
      refreshChatLists(ref.invalidate);
    } catch (_) {}
    final saved = state.chat?.messages[reply.id] ?? reply;
    if (!run.stopped) {
      _speak(run, saved.content, done: true);
      unawaited(
        _afterDone(saved.content, chat.id, state.chat?.title ?? chat.title),
      );
    }
    state = state.copyWith(
      streaming: false,
      clearStatus: true,
      error: saved.error ?? state.error,
    );
  }

  /// Reads one reply out loud in the model's voice (the speaker under a
  /// reply), whether or not read aloud is switched on.
  Future<void> readOut(ChatMessage reply) async {
    final speaker = ref.read(readAloudProvider);
    await speaker.stop();
    final models = await ref.read(modelsProvider.future);
    final id = reply.model ?? state.modelId;
    final settings = await _optional(userSettingsProvider);
    speaker
      ..useVoice(
        speechVoice(
          settings,
          await _optional(serverConfigProvider),
          models.where((m) => m.id == id).firstOrNull?.meta,
        ),
        rate: speechRate(settings),
      )
      ..say(reply.content);
  }

  /// Follow-up suggestions arrive after the reply itself is finished.
  void _afterReply(Map<String, dynamic> event) {
    final outer = event['data'];
    if (outer is! Map || outer['type'] != 'chat:message:follow_ups') return;
    final chat = state.chat;
    final message = chat?.messages[event['message_id']];
    if (chat == null || message == null || event['chat_id'] != chat.id) return;
    final list = ((outer['data'] as Map?)?['follow_ups'] as List? ?? const [])
        .whereType<String>()
        .toList();
    message.extra['followUps'] = list;
    state = state.copyWith(chat: chat);
  }

  /// Hands read aloud what is newly ready to say, when it is on.
  void _speak(_Run run, String text, {bool done = false}) {
    if (voiceCall || !ref.read(readAloudOnProvider)) return;
    // Comparing: only the chosen model's reply is read aloud.
    if ((run.reply.extra['modelIdx'] ?? 0) != 0) return;
    if (run.spoken > text.length) run.spoken = text.length;
    final end = done ? text.length : readyUpTo(text, run.spoken);
    if (end <= run.spoken || (!done && end - run.spoken < 40)) return;
    ref.read(readAloudProvider).say(text.substring(run.spoken, end));
    run.spoken = end;
  }

  List<Map<String, dynamic>> _liveOutput(ChatMessage reply) => [
    for (final item
        in (reply.extra['output'] as List? ?? const []).whereType<Map>())
      item.cast<String, dynamic>(),
  ];

  /// True during a voice call: replies are asked for in a spoken style
  /// (the web UI's `voice` feature).
  bool voiceCall = false;

  Map<String, dynamic> _withVoice(Map<String, dynamic> options) {
    if (!voiceCall) return options;
    return {
      ...options,
      'features': {...(options['features'] as Map? ?? const {}), 'voice': true},
    };
  }

  // ---- Voice calls (the web UI's Chat.svelte call callbacks) ----

  /// Adds a spoken message to the visible conversation and saves it: the
  /// whole chat when it's new, else just this message.
  Future<String> addVoiceMessage(
    String role,
    String content,
    Map<String, dynamic> voice, [
    String? parentId,
  ]) async {
    final modelId = state.modelId;
    var chat =
        state.chat ??
        Chat(
          id: '',
          title: _titleFrom(content),
          messages: {},
          models: [?modelId],
        );
    parentId ??= chat.currentId;
    final branch = chat.thread;
    var parentIndex = branch.indexWhere((m) => m.id == parentId);
    // A chat answer may have been added while this spoken reply was made:
    // keep the reply on that branch, before the next user turn.
    if (role == 'assistant' && parentIndex >= 0) {
      while (parentIndex + 1 < branch.length &&
          branch[parentIndex + 1].role == 'assistant') {
        parentIndex++;
      }
      parentId = branch[parentIndex].id;
    }
    final next = parentIndex >= 0 && parentIndex + 1 < branch.length
        ? branch[parentIndex + 1]
        : null;
    final message = ChatMessage(
      id: _uuid.v4(),
      role: role,
      content: content,
      parentId: parentId,
      model: role == 'assistant' ? voice['model'] as String? : null,
      extra: {
        'done': true,
        'meta': {'voice': voice},
        if (role == 'assistant') ...{
          'modelName': voice['model'],
          'modelIdx': 0,
        } else
          'models': [?modelId],
      },
    );
    final changed = <String, ChatMessage>{message.id: message};
    chat.messages[message.id] = message;
    final parent = parentId == null ? null : chat.messages[parentId];
    if (parent != null) {
      parent.childrenIds.add(message.id);
      // A second transcript can come before the first spoken reply is done:
      // put the reply before the next user message, on the same branch.
      if (role == 'assistant' && next?.role == 'user') {
        next!.parentId = message.id;
        message.childrenIds.add(next.id);
        parent.childrenIds.remove(next.id);
        changed[next.id] = next;
      }
    }
    if (chat.currentId == parentId) chat.currentId = message.id;
    state = state.copyWith(chat: chat);

    final client = ref.read(clientProvider);
    if (chat.id.isEmpty) {
      final created = await client.createChat(chat);
      chat.id = created.id;
      refreshChatLists(ref.invalidate);
    } else {
      // Only the new message, so a running reply keeps its output.
      await client.patchChat(chat.id, {
        'history': {
          'currentId': chat.currentId,
          'messages': {
            for (final e in changed.entries) e.key: e.value.toJson(),
          },
        },
      });
    }
    state = state.copyWith(chat: chat);
    return message.id;
  }

  /// Merges a call's voice details into message [id] and saves them.
  Future<void> saveVoice(String id, Map<String, dynamic> voice) async {
    final chat = state.chat;
    final message = chat?.messages[id];
    if (chat == null || message == null) return;
    final meta = (message.extra['meta'] as Map?)?.cast<String, dynamic>() ?? {};
    final previous = (meta['voice'] as Map?)?.cast<String, dynamic>() ?? {};
    final speech = <String, dynamic>{
      for (final s
          in (previous['speech'] as List? ?? const []).whereType<Map>())
        '${s['item_id']}': s,
      for (final s in (voice['speech'] as List? ?? const []).whereType<Map>())
        '${s['item_id']}': s,
    };
    final merged = {...previous, ...voice, 'speech': speech.values.toList()};
    message.extra['meta'] = {...meta, 'voice': merged};
    state = state.copyWith(chat: chat);
    if (chat.id.isNotEmpty) {
      await ref.read(clientProvider).saveMessageVoice(chat.id, id, merged);
    }
  }

  /// Has the chat model answer a spoken message already in the chat.
  /// Deferred while another reply is still running.
  Future<BridgeSubmission> submitVoice({
    required String userMessageId,
    required String modelId,
  }) async {
    final chat = state.chat;
    final user = chat?.messages[userMessageId];
    if (chat == null || user == null || state.streaming) {
      return const BridgeSubmission('deferred');
    }
    chat.currentId = user.id;
    final started = Completer<({String replyId, List<String> taskIds})>();
    unawaited(_reply(chat, user, modelId, started: started));
    try {
      final s = await started.future;
      return BridgeSubmission(
        'submitted',
        assistantMessageId: s.replyId,
        taskIds: s.taskIds,
      );
    } catch (_) {
      return const BridgeSubmission('rejected');
    }
  }

  /// Stops reply [messageId] and waits until the server confirms it.
  Future<void> stopReply(String messageId) async {
    final run = _run;
    if (run == null || run.reply.id != messageId) return;
    run.reply.extra['bridgeStopping'] = true;
    run.stopped = true;
    unawaited(ref.read(readAloudProvider).stop());
    await _stopTasks(run);
    await run.finished.future.timeout(const Duration(seconds: 15));
    run.reply.extra
      ..remove('bridgeStopping')
      ..['bridgeCancelled'] = true;
  }

  /// Documents in the conversation for the server to search, as the web UI
  /// sends them; photos aren't included, the model sees those directly.
  List<Map<String, dynamic>>? _documents(Chat chat) {
    final seen = <String>{};
    final docs = [
      for (final m in chat.thread)
        for (final f in m.attachments)
          if (!f.isImage && !f.isAudio && seen.add(f.id ?? f.url ?? f.name))
            f.toJson(),
    ];
    return docs.isEmpty ? null : docs;
  }

  /// Settings that only refine a message; a failure to read them must not
  /// stop it from being sent.
  static bool _uiFlag(Map<String, dynamic>? settings, String key) =>
      (settings?['ui'] as Map?)?[key] == true;

  /// Settings > Interface: a tap when a reply is done, and copying it.
  Future<void> _afterDone(String text, String chatId, String title) async {
    final settings = await _optional(userSettingsProvider);
    // Settings > Notifications: tell the phone when nobody's looking.
    if (_uiFlag(settings, 'notificationEnabled') &&
        appInBackground &&
        chatId.isNotEmpty) {
      await notifyReply(
        title: title.isEmpty ? 'Reply ready' : title,
        reply: text,
        chatId: chatId,
        sound: (settings?['ui'] as Map?)?['notificationSound'] != false,
      );
    }
    try {
      if (_uiFlag(settings, 'hapticFeedback')) {
        await HapticFeedback.lightImpact();
      }
      if (_uiFlag(settings, 'responseAutoCopy') && text.trim().isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: text));
      }
    } catch (_) {}
  }

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
        if (saved != null &&
            (saved.done || saved.error != null || pendingCall(saved) != null)) {
          run.finish();
        }
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
