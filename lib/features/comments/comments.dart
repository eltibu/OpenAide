/// Comment threads (Open WebUI 0.13): comments with replies, reactions and
/// mentions on chats, notes, models, knowledge, prompts, skills and tools,
/// including on one message of a chat or a passage of it. Shown when an
/// admin turns on Comments (Admin Settings > General, `enable_comments`).
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/chat_socket.dart';
import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme.dart';
import '../../core/widgets/markdown_style.dart';
import '../channels/channels_api.dart' show showMentions;
import '../chat/chat_controller.dart' show serverConfigProvider;

/// What comments can be on, as the server names it.
const commentResourceTypes = {
  'chat',
  'note',
  'model',
  'knowledge',
  'prompt',
  'skill',
  'tool',
};

/// Whether the server has comments on.
bool commentsOn(WidgetRef ref) =>
    ((ref.watch(serverConfigProvider).value?['features']
        as Map?)?['enable_comments']) ==
    true;

/// A chat only takes comments once it is saved (not temporary).
bool commentableChat(String? id) =>
    id != null &&
    id.isNotEmpty &&
    !id.startsWith('temporary:') &&
    !id.startsWith('local:') &&
    !id.startsWith('channel:');

/// A passage of a message or note page a comment points at, as the web
/// sends it.
class CommentAnchor {
  CommentAnchor._(this.json);
  final Map<String, dynamic> json;

  String get quote => '${json['quote'] ?? ''}';

  /// The anchor for [quote] inside [content] (a message's text), or null
  /// when it isn't found there, so a general comment is made instead.
  static CommentAnchor? find({
    required String quote,
    required String content,
    String surfaceId = 'content',
  }) {
    final q = quote.trim();
    if (q.isEmpty) return null;
    final chars = content.runes.toList();
    final at = content.indexOf(q);
    if (at < 0) return null;
    // Offsets in characters (code points), as the server counts them.
    final start = content.substring(0, at).runes.length;
    final len = q.runes.length;
    String slice(int a, int b) => String.fromCharCodes(chars.sublist(a, b));
    return CommentAnchor._({
      'quote': q,
      'prefix': slice((start - 64).clamp(0, start), start),
      'suffix': slice(start + len, (start + len + 64).clamp(0, chars.length)),
      'start': start,
      'end': start + len,
      'surface_id': surfaceId,
      'source': sha256.convert(utf8.encode(content)).toString(),
      'content_hash': sha256.convert(utf8.encode(content)).toString(),
    });
  }
}

class Comment {
  Comment(this.raw);
  final Map<String, dynamic> raw;

  String get id => '${raw['id']}';
  String get content => '${raw['content'] ?? ''}';
  String? get parentId => raw['parent_id'] as String?;
  String? get replyToId => raw['reply_to_id'] as String?;
  String get etag => '${raw['etag'] ?? raw['updated_at'] ?? ''}';
  bool get deleted => raw['deleted_at'] != null;
  bool get canEdit => raw['can_edit'] == true;
  bool get canDelete => raw['can_delete'] == true;
  int get replyCount => (raw['reply_count'] as num?)?.toInt() ?? 0;
  String get author =>
      '${(raw['user'] as Map?)?['name'] ?? (deleted ? '' : tr('Unknown User'))}';
  String? get quote =>
      ((raw['meta'] as Map?)?['anchor'] as Map?)?['quote'] as String?;
  String? get targetType => raw['target_type'] as String?;
  String? get targetId => raw['target_id'] as String?;

  /// Epoch nanoseconds.
  DateTime get created => DateTime.fromMicrosecondsSinceEpoch(
    ((raw['created_at'] as num?)?.toInt() ?? 0) ~/ 1000,
  );
  bool get edited =>
      !deleted &&
      ((raw['updated_at'] as num?)?.toInt() ?? 0) >
          ((raw['created_at'] as num?)?.toInt() ?? 0);

  List<({String name, int count, bool mine})> get reactions => [
    for (final r in raw['reactions'] as List? ?? const [])
      if (r is Map)
        (
          name: '${r['name']}',
          count: (r['count'] as num?)?.toInt() ?? 0,
          mine: r['reacted'] == true,
        ),
  ];
}

class CommentsApi {
  CommentsApi(this.client);
  final OpenWebUiClient client;

  static const _base = '/api/v1/comments';
  String _c(String id) => '$_base/${Uri.encodeComponent(id)}';

  Future<({List<Comment> items, String? next, int total})> list(
    String type,
    String id, {
    String? cursor,
    int limit = 20,
  }) async {
    final res = await client.send(
      'GET',
      '$_base/',
      query: {
        'resource_type': type,
        'resource_id': id,
        'limit': '$limit',
        'cursor': ?cursor,
      },
    );
    final m = (res as Map?) ?? const {};
    return (
      items: [
        for (final c in m['items'] as List? ?? const [])
          if (c is Map) Comment(c.cast<String, dynamic>()),
      ],
      next: m['next_cursor'] as String?,
      total: (m['total'] as num?)?.toInt() ?? 0,
    );
  }

  /// How many comments [type]/[id] has.
  Future<int> count(String type, String id) async =>
      (await list(type, id, limit: 1)).total;

  Future<Comment> create(
    String type,
    String id,
    String content, {
    String? targetType,
    String? targetId,
    CommentAnchor? anchor,
    String? tempId,
  }) async => Comment(
    ((await client.send(
      'POST',
      '$_base/',
      body: {
        'resource_type': type,
        'resource_id': id,
        'content': content,
        'temp_id': tempId ?? const Uuid().v4(),
        if (targetId != null) ...{
          'target_type': targetType,
          'target_id': targetId,
        },
        if (anchor != null && targetId != null) 'anchor': anchor.json,
      },
    )) as Map).cast<String, dynamic>(),
  );

  Future<List<Comment>> replies(String id) async {
    final out = <Comment>[];
    String? cursor;
    do {
      final res =
          (await client.send(
            'GET',
            '${_c(id)}/replies',
            query: {'limit': '100', 'cursor': ?cursor},
          ) as Map?) ??
          const {};
      out.addAll([
        for (final c in res['items'] as List? ?? const [])
          if (c is Map) Comment(c.cast<String, dynamic>()),
      ]);
      cursor = res['next_cursor'] as String?;
    } while (cursor != null);
    return out;
  }

  Future<Comment> reply(String id, String content, {String? replyToId}) async =>
      Comment(
        ((await client.send(
          'POST',
          '${_c(id)}/replies',
          body: {
            'content': content,
            'temp_id': const Uuid().v4(),
            'reply_to_id': ?replyToId,
          },
        )) as Map).cast<String, dynamic>(),
      );

  Future<void> edit(Comment c, String content) => client.send(
    'PATCH',
    _c(c.id),
    body: {'content': content, 'etag': c.etag},
  );

  Future<void> delete(Comment c) =>
      client.send('DELETE', _c(c.id), query: {'etag': c.etag});

  Future<void> react(String id, String name, {required bool on}) => on
      ? client.send('PUT', '${_c(id)}/reactions', body: {'name': name})
      : client.send('DELETE', '${_c(id)}/reactions', query: {'name': name});

  /// People who can see [type]/[id], for @ mentions.
  Future<List<({String id, String name})>> mentions(
    String type,
    String id,
    String query,
  ) async => [
    for (final u
        in (await client.send(
              'GET',
              '$_base/mentions',
              query: {'resource_type': type, 'resource_id': id, 'query': query},
            ) as List?) ??
            const [])
      if (u is Map) (id: '${u['id']}', name: '${u['name']}'),
  ];
}

final commentsApiProvider = Provider(
  (ref) => CommentsApi(ref.watch(clientProvider)),
);

/// How many comments something has; refreshed when they change.
final commentCountProvider = FutureProvider.autoDispose
    .family<int, (String, String)>((ref, r) async {
      final sub = ref
          .read(chatSocketProvider)
          .commentsChanged
          .where((e) => e['resource_type'] == r.$1 && e['resource_id'] == r.$2)
          .listen((_) => ref.invalidateSelf());
      ref.onDispose(sub.cancel);
      return ref.read(commentsApiProvider).count(r.$1, r.$2);
    });

/// A speech-bubble button with the count, for app bars and menus; nothing
/// when comments are off.
class CommentsButton extends ConsumerWidget {
  const CommentsButton({
    super.key,
    required this.type,
    required this.id,
    this.title,
  });
  final String type;
  final String id;
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!commentsOn(ref) || id.isEmpty) return const SizedBox.shrink();
    if (type == 'chat' && !commentableChat(id)) return const SizedBox.shrink();
    final count = ref.watch(commentCountProvider((type, id))).value ?? 0;
    return IconButton(
      tooltip: tr('Comments'),
      onPressed: () => showComments(context, type: type, id: id, title: title),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const Icon(Icons.mode_comment_outlined),
      ),
    );
  }
}

/// Opens the comments on [type]/[id]. With [targetId] (a chat message or a
/// note page) the new comment points at it, and at [anchor]'s passage.
Future<void> showComments(
  BuildContext context, {
  required String type,
  required String id,
  String? title,
  String? targetType,
  String? targetId,
  CommentAnchor? anchor,
  bool compose = false,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.75,
    minChildSize: 0.4,
    maxChildSize: 1,
    builder: (context, scroll) => CommentsPanel(
      type: type,
      id: id,
      title: title,
      targetType: targetType,
      targetId: targetId,
      anchor: anchor,
      compose: compose,
      scroll: scroll,
    ),
  ),
);

/// The comments on one thing: newest at the bottom, replies folded under
/// each, a box to write at the bottom.
class CommentsPanel extends ConsumerStatefulWidget {
  const CommentsPanel({
    super.key,
    required this.type,
    required this.id,
    this.title,
    this.targetType,
    this.targetId,
    this.anchor,
    this.compose = false,
    this.scroll,
  });
  final String type;
  final String id;
  final String? title;
  final String? targetType;
  final String? targetId;
  final CommentAnchor? anchor;
  final bool compose;
  final ScrollController? scroll;

  @override
  ConsumerState<CommentsPanel> createState() => _CommentsPanelState();
}

class _CommentsPanelState extends ConsumerState<CommentsPanel> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _sub = 'app-${const Uuid().v4()}';
  // Kept for dispose, where ref may no longer be used.
  late final ChatSocket _socket;
  List<Comment> _items = const [];
  final _replies = <String, List<Comment>>{};
  final _open = <String>{};
  String? _next;
  int _total = 0;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  Comment? _replyTo;
  Comment? _editing;
  late String? _targetId = widget.targetId;
  late CommentAnchor? _anchor = widget.anchor;
  final _mentioned = <String, String>{};
  StreamSubscription? _changes;
  Timer? _debounce;

  CommentsApi get _api => ref.read(commentsApiProvider);

  @override
  void initState() {
    super.initState();
    final socket = _socket = ref.read(chatSocketProvider);
    socket.joinComments(_sub, widget.type, widget.id);
    _changes = socket.commentsChanged
        .where(
          (e) =>
              e['resource_type'] == widget.type &&
              e['resource_id'] == widget.id,
        )
        .listen((_) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 150), _load);
        });
    _load();
    if (widget.compose) _focus.requestFocus();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _changes?.cancel();
    _socket.leaveComments(_sub);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    try {
      final page = await _api.list(
        widget.type,
        widget.id,
        cursor: more ? _next : null,
        limit: 50,
      );
      final items = more ? [..._items, ...page.items] : page.items;
      for (final id in _open.toList()) {
        _replies[id] = await _api.replies(id);
      }
      if (!mounted) return;
      setState(() {
        _items = items;
        _next = page.next;
        _total = page.total;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is ApiException ? e.message : '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _toggleReplies(Comment c) async {
    if (_open.remove(c.id)) return setState(() {});
    _open.add(c.id);
    setState(() {});
    try {
      final r = await _api.replies(c.id);
      if (mounted) setState(() => _replies[c.id] = r);
    } catch (e) {
      _say('$e');
    }
  }

  void _say(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr(text))));
    }
  }

  /// The text as sent: each picked @name becomes the server's mention tag.
  String _withMentions(String text) {
    var out = text;
    for (final e in _mentioned.entries) {
      out = out.replaceAll('@${e.value}', '<@U:${e.key}|${e.value}>');
    }
    return out;
  }

  /// The tags shown as @name again, for editing.
  String _plain(String text) =>
      text.replaceAllMapped(RegExp(r'<@U:([^|>]+)\|([^>]+)>'), (m) {
        _mentioned[m[1]!] = m[2]!;
        return '@${m[2]}';
      });

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _saving) return;
    setState(() => _saving = true);
    final content = _withMentions(text);
    try {
      if (_editing != null) {
        await _api.edit(_editing!, content);
      } else if (_replyTo != null) {
        final root = _replyTo!.parentId ?? _replyTo!.id;
        await _api.reply(
          root,
          content,
          replyToId: _replyTo!.parentId == null ? null : _replyTo!.id,
        );
        _open.add(root);
      } else {
        await _api.create(
          widget.type,
          widget.id,
          content,
          targetType: _targetId == null ? null : widget.targetType,
          targetId: _targetId,
          anchor: _anchor,
        );
        _targetId = null;
        _anchor = null;
      }
      _input.clear();
      _mentioned.clear();
      _replyTo = null;
      _editing = null;
      ref.invalidate(commentCountProvider((widget.type, widget.id)));
      await _load();
    } catch (e) {
      _say(e is ApiException ? e.message : '$e');
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _mention() async {
    final picked = await showModalBottomSheet<({String id, String name})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) =>
          _MentionPicker(api: _api, type: widget.type, id: widget.id),
    );
    if (picked == null) return;
    _mentioned[picked.id] = picked.name;
    final tag = '@${picked.name} ';
    final sel = _input.selection;
    final at = sel.isValid ? sel.start : _input.text.length;
    _input.text = _input.text.replaceRange(at, sel.isValid ? sel.end : at, tag);
    _input.selection = TextSelection.collapsed(offset: at + tag.length);
    _focus.requestFocus();
  }

  Future<void> _menu(Comment c) async {
    const quick = ['👍', '❤️', '😂', '🎉', '👀', '🙏'];
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final e in quick)
                  IconButton(
                    onPressed: () => Navigator.pop(sheet, 'react:$e'),
                    icon: Text(e, style: const TextStyle(fontSize: 24)),
                  ),
              ],
            ),
            ListTile(
              leading: const Icon(Icons.reply),
              title: const T('Reply'),
              onTap: () => Navigator.pop(sheet, 'reply'),
            ),
            if (c.canEdit)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const T('Edit'),
                onTap: () => Navigator.pop(sheet, 'edit'),
              ),
            if (c.canDelete)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const T('Delete'),
                onTap: () => Navigator.pop(sheet, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action.startsWith('react:')) {
      return _react(c, action.substring(6));
    }
    switch (action) {
      case 'reply':
        setState(() {
          _replyTo = c;
          _editing = null;
        });
        _focus.requestFocus();
      case 'edit':
        setState(() {
          _editing = c;
          _replyTo = null;
          _input.text = _plain(c.content);
        });
        _focus.requestFocus();
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: const T('Delete comment?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const T('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(d, true),
                child: const T('Delete'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        try {
          await _api.delete(c);
          ref.invalidate(commentCountProvider((widget.type, widget.id)));
          await _load();
        } catch (e) {
          _say(e is ApiException ? e.message : '$e');
        }
    }
  }

  Future<void> _react(Comment c, String name) async {
    final mine = c.reactions.any((r) => r.name == name && r.mine);
    try {
      await _api.react(c.id, name, on: !mine);
      await _load();
    } catch (e) {
      _say(e is ApiException ? e.message : '$e');
    }
  }

  Widget _comment(Comment c, {bool reply = false}) {
    final muted = context.nexus.muted;
    final replies = _replies[c.id] ?? const <Comment>[];
    final open = _open.contains(c.id);
    final replyTo = reply && c.replyToId != null
        ? replies
              .followedBy(_replies.values.expand((l) => l))
              .where((r) => r.id == c.replyToId)
              .firstOrNull
        : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(reply ? 44 : 16, 6, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onLongPress: c.deleted ? null : () => _menu(c),
            onTap: c.deleted ? null : () => _menu(c),
            borderRadius: BorderRadius.circular(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: reply ? 12 : 15,
                  child: Text(
                    c.author.isEmpty ? '?' : c.author.characters.first,
                    style: TextStyle(fontSize: reply ? 11 : 13),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: c.deleted ? tr('Deleted') : c.author,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            TextSpan(
                              text:
                                  '  ${MaterialLocalizations.of(context).formatShortDate(c.created)}'
                                  ' ${TimeOfDay.fromDateTime(c.created).format(context)}'
                                  '${c.edited ? ' · ${tr('Edited')}' : ''}',
                              style: TextStyle(color: muted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      if (replyTo != null)
                        Text(
                          '↪ ${replyTo.author}',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                      if ((c.quote ?? '').isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.only(left: 8),
                          decoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(color: muted, width: 3),
                            ),
                          ),
                          child: Text(
                            c.quote!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: muted,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        )
                      else if (c.targetType == 'chat_message' && !reply)
                        Text(
                          tr('On a message'),
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                      if (c.deleted)
                        T(
                          'This comment was deleted.',
                          style: TextStyle(color: muted),
                        )
                      else
                        MarkdownBlock(
                          data: showMentions(c.content),
                          selectable: false,
                          config: nexusMarkdown(context),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (c.reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 2),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final r in c.reactions)
                    FilterChip(
                      visualDensity: VisualDensity.compact,
                      selected: r.mine,
                      label: Text('${r.name} ${r.count}'),
                      onSelected: (_) => _react(c, r.name),
                    ),
                ],
              ),
            ),
          if (!reply && c.replyCount > 0)
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: TextButton(
                onPressed: () => _toggleReplies(c),
                child: Text(
                  open
                      ? tr('Hide replies')
                      : c.replyCount == 1
                      ? tr('1 reply')
                      : tr('{{COUNT}} replies')
                            .replaceAll('{{COUNT}}', '${c.replyCount}'),
                ),
              ),
            ),
          if (open)
            for (final r in replies) _comment(r, reply: true),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final hint = _editing != null
        ? tr('Edit comment')
        : _replyTo != null
        ? tr('Reply to {{name}}').replaceAll('{{name}}', _replyTo!.author)
        : tr('Add a comment');
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title == null || widget.title!.isEmpty
                        ? tr('Comments')
                        : '${tr('Comments')} · ${widget.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_total > 0) Text('$_total', style: TextStyle(color: muted)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? ListView(
                    controller: widget.scroll,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!),
                      ),
                    ],
                  )
                : ListView(
                    controller: widget.scroll,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      if (_items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Center(
                            child: T(
                              'No comments yet',
                              style: TextStyle(color: muted),
                            ),
                          ),
                        ),
                      for (final c in _items) _comment(c),
                      if (_next != null)
                        Center(
                          child: TextButton(
                            onPressed: () => _load(more: true),
                            child: const T('Load more'),
                          ),
                        ),
                    ],
                  ),
          ),
          const Divider(height: 1),
          if (_replyTo != null || _editing != null || _targetId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _editing != null
                          ? tr('Editing')
                          : _replyTo != null
                          ? tr('Replying to {{name}}')
                                .replaceAll('{{name}}', _replyTo!.author)
                          : _anchor != null
                          ? '“${_anchor!.quote}”'
                          : tr('On this message'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Cancel'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() {
                      if (_editing != null) _input.clear();
                      _editing = null;
                      _replyTo = null;
                      _targetId = null;
                      _anchor = null;
                    }),
                  ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: tr('Mention someone'),
                    icon: const Icon(Icons.alternate_email),
                    onPressed: _mention,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 6,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: hint,
                        isDense: true,
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Send'),
                    onPressed: _saving ? null : _send,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
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

class _MentionPicker extends StatefulWidget {
  const _MentionPicker({
    required this.api,
    required this.type,
    required this.id,
  });
  final CommentsApi api;
  final String type;
  final String id;

  @override
  State<_MentionPicker> createState() => _MentionPickerState();
}

class _MentionPickerState extends State<_MentionPicker> {
  List<({String id, String name})> _people = const [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _search(String q) async {
    try {
      final people = await widget.api.mentions(widget.type, widget.id, q);
      if (mounted) setState(() => _people = people);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: tr('Search people'),
              ),
              onChanged: (q) {
                _debounce?.cancel();
                _debounce = Timer(
                  const Duration(milliseconds: 250),
                  () => _search(q),
                );
              },
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.4,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in _people)
                  ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        p.name.isEmpty ? '?' : p.name.characters.first,
                      ),
                    ),
                    title: Text(p.name),
                    onTap: () => Navigator.pop(context, p),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
