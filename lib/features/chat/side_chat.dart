/// Side chats (Open WebUI 0.13): "/side" or "/btw" opens a side
/// conversation with the chat so far as context, so a quick question or a
/// detour stays out of the main chat. Since Open WebUI 0.13.1 a side chat is
/// saved as its own chat (it shows in the chat list), unless it is switched
/// to Temporary or the admin makes every chat temporary; 0.13.0 servers
/// only had temporary ones.
/// Admins, and people given "Allow Side Chat" (off by default), may use it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/chat.dart';
import '../../core/theme.dart';
import '../../core/widgets/markdown_style.dart';
import '../settings/settings_screen.dart' show meProvider;
import 'chat_controller.dart';

const _sidePrompt =
    'This is a separate side conversation. Earlier messages are reference '
    'context only. Answer the side question; do not continue the parent task.';

/// Whether [me] may open side chats, as the web decides it.
/// Open WebUI 0.13.1 dropped the need for the Temporary Chat permission.
bool sideChatAllowed(Map? me) {
  if (me == null) return false;
  if (me['role'] == 'admin') return true;
  final chat = (me['permissions'] as Map?)?['chat'] as Map?;
  return me['role'] == 'user' && (chat?['side_chat'] ?? false) == true;
}

/// Whether [me] may keep side chats (not when every chat must be temporary).
bool sideChatCanSave(Map? me) =>
    me?['role'] == 'admin' ||
    ((me?['permissions'] as Map?)?['chat'] as Map?)?['temporary_enforced'] !=
        true;

/// Whether [me] may use temporary chats.
bool sideChatCanBeTemporary(Map? me) =>
    me?['role'] == 'admin' ||
    (((me?['permissions'] as Map?)?['chat'] as Map?)?['temporary'] ?? true) ==
        true;

/// Whether the server keeps side chats (Open WebUI 0.13.1 and later).
bool serverSavesSideChats(String? version) {
  final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(version ?? '');
  if (m == null) return true;
  final v = [for (var i = 1; i <= 3; i++) int.parse(m[i]!)];
  if (v[0] != 0) return v[0] > 0;
  if (v[1] != 13) return v[1] > 13;
  return v[2] >= 1;
}

/// The chat so far, as a history for a saved side chat: one branch, each
/// message pointing at the next.
Map<String, dynamic> sideChatHistory(List<Map<String, dynamic>> branch) {
  final messages = <String, dynamic>{};
  for (final (i, m) in branch.indexed) {
    messages['${m['id']}'] = {
      ...m,
      'parentId': i == 0 ? null : branch[i - 1]['id'],
      'childrenIds': [if (i + 1 < branch.length) branch[i + 1]['id']],
    };
  }
  return {'messages': messages, 'currentId': branch.lastOrNull?['id']};
}

/// Opens a side chat on the open chat, asking [question] first if given.
Future<void> openSideChat(BuildContext context, {String question = ''}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        minChildSize: 0.4,
        maxChildSize: 1,
        builder: (context, scroll) =>
            SideChat(question: question, scroll: scroll),
      ),
    );

class SideChat extends ConsumerStatefulWidget {
  const SideChat({super.key, this.question = '', this.scroll});
  final String question;
  final ScrollController? scroll;

  @override
  ConsumerState<SideChat> createState() => _SideChatState();
}

class _SideChatState extends ConsumerState<SideChat> {
  final _input = TextEditingController();
  final _messages = <ChatMessage>[];
  late final List<Map<String, dynamic>> _context;
  late final List<Map<String, dynamic>> _branch;
  late final String? _model;
  late final String? _parentChat;
  late final String? _folder;
  String? _id;

  /// Not saved: on 0.13.0 servers, when switched on, or when the admin
  /// makes every chat temporary.
  late bool _temporary;
  String? _error;
  ChatMessage? _answer;
  List<String> _tasks = const [];
  StreamSubscription? _events;

  @override
  void initState() {
    super.initState();
    // The chat's branch as it is now; what happens there later stays there.
    final state = ref.read(chatControllerProvider);
    _model = state.modelId;
    _parentChat = (state.chat?.id.isEmpty ?? true) || state.temporary
        ? null
        : state.chat!.id;
    _folder = state.folderId;
    _branch = [
      for (final m in state.messages)
        if (m.role == 'user' || m.role == 'assistant') m.toJson(),
    ];
    final me = ref.read(meProvider).value;
    _temporary =
        !serverSavesSideChats(
          '${ref.read(serverConfigProvider).value?['version'] ?? ''}',
        ) ||
        !sideChatCanSave(me);
    _context = [
      for (final m in state.messages)
        if ((m.role == 'user' || m.role == 'assistant') &&
            m.content.trim().isNotEmpty)
          {'role': m.role, 'content': m.content},
    ];
    if (widget.question.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ask(widget.question.trim()),
      );
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    _stop();
    _input.dispose();
    super.dispose();
  }

  void _stop() {
    final client = ref.read(clientProvider);
    for (final t in _tasks) {
      unawaited(client.stopTask(t).catchError((_) {}));
    }
    _tasks = const [];
  }

  Future<void> _ask(String question) async {
    if (question.isEmpty || _answer != null || _model == null) return;
    final socket = ref.read(chatSocketProvider);
    final sid = await socket.ready();
    if (sid == null) {
      setState(
        () => _error = tr(
          "Side chats need a live connection to the server, and it isn't "
          'connected right now. Try again in a moment.',
        ),
      );
      return;
    }
    final client = ref.read(clientProvider);
    final first = _id == null;
    if (_id == null && _temporary) {
      // A temporary chat the server ties to this connection.
      _id = 'temporary:$sid:${const Uuid().v4()}';
    } else if (_id == null) {
      // Saved as its own chat, branching off this one, as the web does.
      try {
        final created = await client.createSideChat(
          title: question.length > 100 ? question.substring(0, 100) : question,
          model: _model,
          system: _sidePrompt,
          history: sideChatHistory(_branch),
          messages: _branch,
          originalChatId: _parentChat,
          branchPointMessageId: _branch.lastOrNull?['id'] as String?,
          folderId: _folder,
        );
        _id = created;
        ref.invalidate(chatListProvider);
      } catch (e) {
        if (mounted) {
          setState(() => _error = e is ApiException ? e.message : '$e');
        }
        return;
      }
    }
    if (!mounted) return;
    final user = ChatMessage(
      id: const Uuid().v4(),
      role: 'user',
      content: question,
      parentId:
          _messages.lastOrNull?.id ??
          (_temporary ? null : _branch.lastOrNull?['id'] as String?),
    );
    final answer = ChatMessage(
      id: const Uuid().v4(),
      role: 'assistant',
      content: '',
      parentId: user.id,
      model: _model,
    );
    final history = [
      for (final m in _messages) {'role': m.role, 'content': m.content},
    ];
    setState(() {
      _messages
        ..add(user)
        ..add(answer);
      _answer = answer;
      _error = null;
    });
    _input.clear();
    _events?.cancel();
    _events = socket.events
        .where((e) => e['chat_id'] == _id && e['message_id'] == answer.id)
        .listen(_onEvent);
    try {
      final turn = await ref
          .read(clientProvider)
          .startTurn(
            model: _model,
            chatId: _id,
            userMessage: user,
            replyId: answer.id,
            sessionId: sid,
            messages: [
              {'role': 'system', 'content': _sidePrompt},
              ..._context,
              ...history,
              {'role': 'user', 'content': question},
            ],
            options: {
              'background_tasks': _temporary || !first
                  ? <String, Object>{}
                  : {'title_generation': true, 'tags_generation': true},
            },
          );
      _tasks = turn.taskIds;
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is ApiException ? e.message : '$e';
          _answer = null;
        });
      }
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    final reply = _answer;
    final outer = event['data'];
    if (reply == null || outer is! Map) return;
    final data = outer['data'];
    var done = false;
    switch (outer['type']) {
      case 'response:completion' when data is Map:
        if (data['type'] == 'response.output_text.delta' &&
            data['delta'] is String) {
          reply.content += data['delta'] as String;
        }
      case 'chat:completion' when data is Map:
        final text = data['content'] is String
            ? data['content'] as String
            : ChatMessage.outputText(data['output']);
        if (text.isNotEmpty) reply.content = text;
        if (data['error'] != null) {
          _error = '${(data['error'] as Map?)?['content'] ?? data['error']}';
        }
        done = data['done'] == true || data['error'] != null;
      case 'chat:message:error' when data is Map:
        _error = '${(data['error'] as Map?)?['content'] ?? data['error']}';
        done = true;
      case 'chat:tasks:cancel':
        done = true;
    }
    if (!mounted) return;
    setState(() {
      if (done) {
        _answer = null;
        _tasks = const [];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final busy = _answer != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
            child: Row(
              children: [
                const Icon(Icons.chat_bubble_outline, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: T(
                    'Side chat',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                // Before the first question, a saved side chat can be made
                // temporary (and back), as on the web.
                if (_id == null &&
                    serverSavesSideChats(
                      '${ref.watch(serverConfigProvider).value?['version'] ?? ''}',
                    ) &&
                    sideChatCanSave(ref.watch(meProvider).value) &&
                    sideChatCanBeTemporary(ref.watch(meProvider).value))
                  FilterChip(
                    label: T('Temporary'),
                    selected: _temporary,
                    onSelected: (v) => setState(() => _temporary = v),
                  ),
                IconButton(
                  tooltip: tr('Close'),
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: widget.scroll,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              children: [
                if (_messages.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: T(
                      _temporary
                          ? 'Ask a quick question about this chat. The side '
                                "chat isn't saved and doesn't change the main "
                                'chat.'
                          : 'Ask a quick question about this chat. The side '
                                'chat is saved as its own chat and '
                                "doesn't change the main chat.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: muted),
                    ),
                  ),
                for (final m in _messages)
                  if (m.role == 'user')
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        margin: const EdgeInsets.only(top: 8, left: 40),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: context.nexus.userBubble,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Text(m.content),
                      ),
                    )
                  else if (m.content.isEmpty && m == _answer)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: T('Thinking…', style: TextStyle(color: muted)),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: MarkdownBlock(
                        data: m.content,
                        selectable: m != _answer,
                        config: nexusMarkdown(context),
                      ),
                    ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      autofocus: widget.question.isEmpty,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      onSubmitted: busy ? null : (v) => _ask(v.trim()),
                      decoration: InputDecoration(
                        hintText: tr('Ask on the side'),
                        isDense: true,
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  if (busy)
                    IconButton(
                      tooltip: tr('Stop'),
                      icon: const Icon(Icons.stop_rounded),
                      onPressed: () {
                        _stop();
                        setState(() => _answer = null);
                      },
                    )
                  else
                    IconButton(
                      tooltip: tr('Send'),
                      icon: const Icon(Icons.send),
                      onPressed: () => _ask(_input.text.trim()),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Reads a side chat question from the chat box: "/side …" or "/btw …".
String? sideChatQuestion(String text) {
  final m = RegExp(r'^/(side|btw)(?:\s+([\s\S]*))?$').firstMatch(text.trim());
  return m == null ? null : (m[2] ?? '').trim();
}
