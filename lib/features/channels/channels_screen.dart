import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart' show Attachment;
import '../chat/attachments.dart' show MessageAttachments, imageLimits;
import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import '../studio/record_notes.dart' show dictate;
import 'channel_manage.dart';
import 'encrypted_chat.dart';
import '../workspace/access_editor.dart' show editAccess;
import '../settings/settings_screen.dart' show meProvider;
import 'channels_api.dart';

final channelsApiProvider = Provider<ChannelsApi>(
  (ref) => ChannelsApi(ref.watch(clientProvider)),
);

final channelListProvider = FutureProvider<List<Channel>>((ref) async {
  final list = await ref.watch(channelsApiProvider).list();
  return list..sort(
    (a, b) => (b.lastMessageAt ?? DateTime(2000)).compareTo(
      a.lastMessageAt ?? DateTime(2000),
    ),
  );
});

String? _me(WidgetRef ref) =>
    ref.read(sessionProvider).value?.user?['id'] as String?;
String? _myName(WidgetRef ref) =>
    ref.read(sessionProvider).value?.user?['name'] as String?;

String _clock(BuildContext context, DateTime t) {
  final l10n = MaterialLocalizations.of(context);
  final now = DateTime.now();
  final time = l10n.formatTimeOfDay(TimeOfDay.fromDateTime(t));
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return time;
  }
  return '${l10n.formatShortMonthDay(t)}, $time';
}

/// Every channel and direct message the person is in.
class ChannelsScreen extends ConsumerWidget {
  const ChannelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels = ref.watch(channelListProvider);
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(title: const Text('Channels')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New',
        onPressed: () => _startNew(context, ref),
        child: const Icon(Icons.add_comment_outlined),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(channelListProvider.future),
        child: channels.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load channels.\n$e'),
              ),
            ],
          ),
          data: (list) => ListView(
            children: [
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No channels yet',
                    style: TextStyle(color: muted),
                  ),
                ),
              for (final c in list)
                ListTile(
                  leading: CircleAvatar(
                    child: Icon(c.isDm ? Icons.person_outline : Icons.tag),
                  ),
                  title: Text(
                    c.title(_myName(ref)),
                    style: c.unread > 0
                        ? const TextStyle(fontWeight: FontWeight.w700)
                        : null,
                  ),
                  subtitle: c.description?.isNotEmpty == true
                      ? Text(
                          c.description!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: muted),
                        )
                      : null,
                  trailing: c.unread > 0
                      ? Badge(label: Text('${c.unread}'))
                      : null,
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ChannelScreen(channel: c),
                      ),
                    );
                    ref.invalidate(channelListProvider);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Starts a channel, a group or a direct message, then opens it.
Future<void> _startNew(BuildContext context, WidgetRef ref) async {
  final api = ref.read(channelsApiProvider);
  final admin = ref.read(sessionProvider).value?.user?['role'] == 'admin';
  final kind = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Direct message'),
            onTap: () => Navigator.pop(sheet, 'dm'),
          ),
          ListTile(
            leading: const Icon(Icons.group_outlined),
            title: const Text('Group'),
            subtitle: const Text('Private, for the people you add'),
            onTap: () => Navigator.pop(sheet, 'group'),
          ),
          if (admin)
            ListTile(
              leading: const Icon(Icons.tag),
              title: const Text('Channel'),
              subtitle: const Text('Everyone with access joins'),
              onTap: () => Navigator.pop(sheet, ''),
            ),
        ],
      ),
    ),
  );
  if (kind == null || !context.mounted) return;
  try {
    Channel? made;
    if (kind == 'dm') {
      final me = ref.read(sessionProvider).value?.user?['id'] as String?;
      final who = await pickPerson(
        context,
        api,
        title: 'Message someone',
        skip: {?me},
      );
      if (who == null) return;
      made = await api.directMessage(who.id);
    } else {
      final details = await askChannelDetails(
        context,
        title: kind == 'group' ? 'New group' : 'New channel',
      );
      if (details == null) return;
      made = await api.create(
        details.name,
        description: details.description.isEmpty ? null : details.description,
        type: kind,
      );
    }
    ref.invalidate(channelListProvider);
    if (!context.mounted) return;
    // A fresh read names a direct message by the person in it.
    final full = await api.get(made.id).catchError((_) => made!);
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => ChannelScreen(channel: full)),
    );
    ref.invalidate(channelListProvider);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// Channels on screen now, which need no message toasts.
final openChannels = <String>[];

/// A channel's messages, live, or one thread in it when [parent] is set.
class ChannelScreen extends ConsumerStatefulWidget {
  const ChannelScreen({super.key, required this.channel, this.parent});
  final Channel channel;
  final ChannelMessage? parent;

  @override
  ConsumerState<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends ConsumerState<ChannelScreen> {
  late final ChannelsApi _api = ref.read(channelsApiProvider);
  final _input = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _live;

  /// Newest first.
  List<ChannelMessage> _messages = const [];
  late ChannelMessage? _parent = widget.parent;

  /// The channel as last read, with its mute and member count.
  late Channel _channel = widget.channel;
  Object? _error;
  bool _loading = true;
  bool _more = true;
  bool _sending = false;

  /// The encrypted chat going on here, to join.
  String? _encrypted;
  StreamSubscription<Map<String, dynamic>>? _encryptionSub;

  /// Uploaded and waiting to go with the next message.
  final _pending = <Attachment>[];
  int _uploading = 0;

  bool get _isThread => widget.parent != null;
  String get _id => widget.channel.id;

  @override
  void initState() {
    super.initState();
    openChannels.add(_id);
    _load();
    try {
      final socket = ref.read(chatSocketProvider);
      _live = socket.channelEvents.listen(_onEvent);
      if (!_isThread) {
        _encryptionSub = socket.encryptionAvailable.listen((e) {
          if (e['channel'] == _id && mounted) {
            setState(() => _encrypted = e['session'] as String?);
          }
        });
      }
    } catch (_) {
      // Signed out: nothing live.
    }
  }

  bool get _canEncrypt =>
      !_isThread &&
      encryptionFits(_channel) &&
      canUseEncryption(
        ref.read(meProvider).value,
        ref.read(serverConfigProvider).value?['features'] as Map?,
      );

  Future<void> _checkEncrypted() async {
    try {
      await ref.read(meProvider.future);
      await ref.read(serverConfigProvider.future);
      if (!_canEncrypt) return;
      final session = await ref.read(chatSocketProvider).encryptedChatIn(_id);
      // Also shows the menu's Encrypted Chat once both are read.
      if (mounted) setState(() => _encrypted = session);
    } catch (_) {}
  }

  @override
  void dispose() {
    openChannels.remove(_id);
    _live?.cancel();
    _encryptionSub?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      _messages = _isThread
          ? await _api.thread(_id, widget.parent!.id)
          : await _api.messages(_id);
      if (!_isThread) {
        try {
          _channel = await _api.get(_id);
        } catch (_) {
          // The list's copy will do.
        }
      }
      _more = !_isThread && _messages.length >= 50;
      _error = null;
      _loadFiles(_messages);
      unawaited(_checkEncrypted());
      // Opening a channel joins it; listen to it live from now on.
      try {
        ref.read(chatSocketProvider).joinChannels();
      } catch (_) {}
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadMore() async {
    if (!_more || _loading) return;
    _loading = true;
    try {
      final older = await _api.messages(_id, skip: _messages.length);
      _more = older.length >= 50;
      setState(() => _messages = [..._messages, ...older]);
      _loadFiles(older);
    } catch (_) {}
    _loading = false;
  }

  /// Lists only say a message has files; read each one's on its own.
  Future<void> _loadFiles(List<ChannelMessage> list) async {
    for (final m in [?_parent, ...list]) {
      if (!m.hasFiles || m.files.isNotEmpty) continue;
      try {
        final files = await _api.files(_id, m.id);
        if (!mounted || files.isEmpty) continue;
        setState(() {
          if (_parent?.id == m.id) _parent = _parent!.copyWith(files: files);
          _messages = [
            for (final x in _messages)
              x.id == m.id ? x.copyWith(files: files) : x,
          ];
        });
      } catch (_) {
        // Shown without its files.
      }
    }
  }

  Future<void> _attach() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photos'),
              onTap: () => Navigator.pop(sheet, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(sheet, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('Files'),
              onTap: () => Navigator.pop(sheet, 'files'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    final (maxW, maxH) = imageLimits(
      ref.read(userSettingsProvider).value?['ui'] as Map?,
      channels: true,
    );
    final picker = ImagePicker();
    final picked = <(List<int>, String, String?)>[];
    try {
      if (choice == 'files') {
        for (final f in await FilePicker.pickFiles()) {
          picked.add((await f.readAsBytes(), f.name, null));
        }
      } else {
        final photos = choice == 'camera'
            ? [
                ?await picker.pickImage(
                  source: ImageSource.camera,
                  maxWidth: maxW,
                  maxHeight: maxH,
                  imageQuality: 85,
                ),
              ]
            : await picker.pickMultiImage(
                maxWidth: maxW,
                maxHeight: maxH,
                imageQuality: 85,
              );
        for (final p in photos) {
          picked.add((
            await p.readAsBytes(),
            p.name,
            p.mimeType ?? 'image/jpeg',
          ));
        }
      }
    } catch (e) {
      _say('$e');
      return;
    }
    final client = ref.read(clientProvider);
    for (final (bytes, name, type) in picked) {
      setState(() => _uploading++);
      try {
        final uploaded = await client.uploadFile(
          bytes,
          name,
          contentType: type,
          // Photos are looked at, not read.
          process: type?.startsWith('image/') != true,
        );
        _pending.add(Attachment.uploaded(uploaded, size: bytes.length));
      } catch (e) {
        _say('$name not added: $e');
      }
      if (mounted) setState(() => _uploading--);
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    if (e['channel_id'] != _id) return;
    final inner = (e['data'] as Map?) ?? const {};
    final type = inner['type'];
    final data = inner['data'];
    if (data is! Map) return;
    final m = ChannelMessage.fromJson(data);
    final mine = _isThread
        ? m.parentId == widget.parent!.id
        : m.parentId == null;
    setState(() {
      switch (type) {
        case 'message':
          if (!mine) return;
          if (_messages.any((x) => x.id == m.id)) return;
          _messages = [m, ..._messages];
        case 'message:update':
          if (_isThread && m.id == widget.parent!.id) {
            _parent = m.copyWith(replyCount: _parent?.replyCount);
          }
          _messages = [
            for (final x in _messages)
              x.id == m.id
                  ? m.copyWith(
                      replyCount: x.replyCount,
                      reactions: data.containsKey('reactions')
                          ? m.reactions
                          : x.reactions,
                    )
                  : x,
          ];
        case 'message:delete':
          _messages = [
            for (final x in _messages)
              if (x.id != m.id) x,
          ];
        case 'message:reply':
          // A thread under one of these messages grew.
          _messages = [
            for (final x in _messages)
              x.id == m.id ? x.copyWith(replyCount: x.replyCount + 1) : x,
          ];
        case 'message:reaction:add' || 'message:reaction:remove':
          _refreshOne(m.id);
      }
    });
  }

  Future<void> _refreshOne(String messageId) async {
    try {
      final fresh = await _api.message(_id, messageId);
      if (!mounted) return;
      setState(() {
        if (_parent?.id == messageId) {
          _parent = fresh;
        }
        _messages = [
          for (final x in _messages)
            x.id == messageId ? x.copyWith(reactions: fresh.reactions) : x,
        ];
      });
    } catch (_) {}
  }

  /// Speak a message: what was said goes into the box, to check first.
  Future<void> _dictate() async {
    final said = await dictate(context, ref.read(clientProvider));
    if (said == null || said.trim().isEmpty || !mounted) return;
    final now = _input.text;
    _input.text = now.trim().isEmpty
        ? said.trim()
        : '${now.trimRight()} ${said.trim()}';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if ((text.isEmpty && _pending.isEmpty) || _sending || _uploading > 0) {
      return;
    }
    setState(() => _sending = true);
    try {
      final sent = await _api.post(
        _id,
        text,
        parentId: widget.parent?.id,
        files: [..._pending],
      );
      _input.clear();
      _pending.clear();
      if (!_messages.any((x) => x.id == sent.id)) {
        setState(() => _messages = [sent, ..._messages]);
      }
    } catch (e) {
      _say('Not sent: $e');
    }
    if (mounted) setState(() => _sending = false);
  }

  void _say(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _mention() async {
    final models = ref.read(modelsProvider).value ?? const [];
    final picked = await showModalBottomSheet<(String, String)>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Ask a model'),
            ),
            for (final m in models)
              ListTile(
                leading: const Icon(Icons.auto_awesome_outlined),
                title: Text(m.name),
                onTap: () => Navigator.pop(sheet, (m.id, m.name)),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final tag = '<@M:${picked.$1}|${picked.$2}> ';
    final sel = _input.selection;
    final at = sel.isValid ? sel.start : _input.text.length;
    _input.text = _input.text.replaceRange(at, sel.isValid ? sel.end : at, tag);
    _input.selection = TextSelection.collapsed(offset: at + tag.length);
  }

  Future<void> _menu(ChannelMessage m) async {
    final mine = m.userId == _me(ref) && m.modelName == null;
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
            if (!_isThread)
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: const Text('Reply in thread'),
                onTap: () => Navigator.pop(sheet, 'thread'),
              ),
            if (_channel.raw['write_access'] != false)
              ListTile(
                leading: Icon(
                  m.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                ),
                title: Text(m.pinned ? 'Unpin' : 'Pin'),
                onTap: () => Navigator.pop(sheet, 'pin'),
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy text'),
              onTap: () => Navigator.pop(sheet, 'copy'),
            ),
            if (mine)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () => Navigator.pop(sheet, 'edit'),
              ),
            if (mine ||
                ref.read(sessionProvider).value?.user?['role'] == 'admin')
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete'),
                onTap: () => Navigator.pop(sheet, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    try {
      if (action.startsWith('react:')) {
        await _toggleReaction(m, action.substring(6));
      } else if (action == 'thread') {
        _openThread(m);
      } else if (action == 'pin') {
        await _api.pin(_id, m.id, !m.pinned);
        setState(() {
          if (_parent?.id == m.id) _parent = m.copyWith(pinned: !m.pinned);
          _messages = [
            for (final x in _messages)
              x.id == m.id ? x.copyWith(pinned: !m.pinned) : x,
          ];
        });
        _say(m.pinned ? 'Unpinned' : 'Pinned');
      } else if (action == 'copy') {
        await Clipboard.setData(ClipboardData(text: showMentions(m.content)));
      } else if (action == 'edit') {
        final text = TextEditingController(text: m.content);
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('Edit message'),
            content: TextField(
              controller: text,
              maxLines: null,
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(d, true),
                child: const Text('Save'),
              ),
            ],
          ),
        );
        if (ok == true && text.text.trim().isNotEmpty) {
          await _api.edit(_id, m.id, text.text.trim());
          setState(() {
            _messages = [
              for (final x in _messages)
                x.id == m.id ? x.copyWith(content: text.text.trim()) : x,
            ];
          });
        }
      } else if (action == 'delete') {
        await _api.delete(_id, m.id);
        setState(() {
          _messages = [
            for (final x in _messages)
              if (x.id != m.id) x,
          ];
        });
      }
    } catch (e) {
      _say('$e');
    }
  }

  Future<void> _toggleReaction(ChannelMessage m, String emoji) async {
    final me = _me(ref);
    final has = m.reactions.any(
      (r) => r.name == emoji && r.userIds.contains(me),
    );
    await _api.react(_id, m.id, emoji, !has);
    await _refreshOne(m.id);
  }

  Future<void> _openPinned() async {
    final m = await showPinned(context, _api, _id);
    if (m == null || !mounted) return;
    if (m.parentId != null) {
      // A pinned reply: open its thread.
      try {
        _openThread(await _api.message(_id, m.parentId!));
      } catch (e) {
        _say('$e');
      }
    } else {
      _openThread(m);
    }
  }

  Future<void> _channelAction(String action) async {
    final nav = Navigator.of(context);
    try {
      switch (action) {
        case 'mute':
          final muted = await showModalBottomSheet<bool>(
            context: context,
            showDragHandle: true,
            builder: (sheet) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (on, label) in [
                    (false, 'All messages'),
                    (true, 'Mentions only'),
                  ])
                    ListTile(
                      leading: Icon(
                        _channel.muted == on
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(label),
                      onTap: () => Navigator.pop(sheet, on),
                    ),
                ],
              ),
            ),
          );
          if (muted == null || muted == _channel.muted) return;
          await _api.setMuted(_id, muted);
          _channel = await _api.get(_id);
          if (mounted) setState(() {});
        case 'members':
          await nav.push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  ChannelMembersScreen(api: _api, channel: _channel),
            ),
          );
          _channel = await _api.get(_id);
          if (mounted) setState(() {});
        case 'webhooks':
          await nav.push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  ChannelWebhooksScreen(api: _api, channel: _channel),
            ),
          );
        case 'edit':
          final details = await askChannelDetails(
            context,
            title: 'Edit channel',
            name: _channel.name,
            description: _channel.description ?? '',
            action: 'Save',
          );
          if (details == null) return;
          await _api.update(
            _channel,
            name: details.name,
            description: details.description,
          );
          _channel = await _api.get(_id);
          if (mounted) setState(() {});
          ref.invalidate(channelListProvider);
        case 'access':
          await editAccess(
            context,
            ref,
            kind: 'channel',
            id: _id,
            name: _channel.name,
          );
        case 'visibility':
          await _api.update(_channel, isPrivate: !_channel.isPrivate);
          _channel = await _api.get(_id);
          if (mounted) setState(() {});
          ref.invalidate(channelListProvider);
        case 'delete':
          final ok = await showDialog<bool>(
            context: context,
            builder: (d) => AlertDialog(
              title: Text('Delete #${_channel.name}?'),
              content: const Text(
                'Its messages are deleted for everyone. This can\'t be undone.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(d, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(d, true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (ok != true) return;
          await _api.deleteChannel(_id);
          ref.invalidate(channelListProvider);
          nav.pop();
        case 'encrypted':
          openEncryptedChat(context, _channel, join: false);
        case 'hide':
          await _api.setActive(_id, false);
          ref.invalidate(channelListProvider);
          nav.pop();
      }
    } catch (e) {
      _say('$e');
    }
  }

  void _openThread(ChannelMessage m) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ChannelScreen(channel: widget.channel, parent: m),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final title = _channel.title(_myName(ref));
    final scheme = Theme.of(context).colorScheme;
    final count = _channel.userCount;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_isThread ? 'Thread' : (_channel.isDm ? title : '# $title')),
            if (!_isThread && !_channel.isDm && count != null)
              Text(
                count == 1 ? '1 member' : '$count members',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (_encrypted != null && _canEncrypt)
              InkWell(
                onTap: () => openEncryptedChat(context, _channel, join: true),
                child: Text.rich(
                  TextSpan(
                    text: 'Encrypted chat in progress · ',
                    children: [
                      TextSpan(
                        text: 'Join',
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
        actions: _isThread
            ? null
            : [
                IconButton(
                  tooltip: 'Pinned messages',
                  icon: const Icon(Icons.push_pin_outlined),
                  onPressed: _openPinned,
                ),
                PopupMenuButton<String>(
                  onSelected: _channelAction,
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'mute',
                      child: ListTile(
                        leading: Icon(
                          _channel.muted
                              ? Icons.notifications_off_outlined
                              : Icons.notifications_outlined,
                        ),
                        title: const Text('Notifications'),
                        subtitle: Text(
                          _channel.muted ? 'Mentions only' : 'All messages',
                        ),
                      ),
                    ),
                    if (_canEncrypt)
                      const PopupMenuItem(
                        value: 'encrypted',
                        child: ListTile(
                          leading: Icon(Icons.lock_outline),
                          title: Text('Encrypted Chat'),
                        ),
                      ),
                    if (!_channel.isDm)
                      const PopupMenuItem(
                        value: 'members',
                        child: ListTile(
                          leading: Icon(Icons.group_outlined),
                          title: Text('Members'),
                        ),
                      ),
                    if (!_channel.isDm && canManage(ref, _channel)) ...[
                      const PopupMenuItem(
                        value: 'webhooks',
                        child: ListTile(
                          leading: Icon(Icons.webhook_outlined),
                          title: Text('Webhooks'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Edit channel'),
                        ),
                      ),
                      // A channel: who may read and write, by group
                      // and person (the web's Manage).
                      if (_channel.type.isEmpty)
                        const PopupMenuItem(
                          value: 'access',
                          child: ListTile(
                            leading: Icon(Icons.lock_person_outlined),
                            title: Text('Access'),
                          ),
                        ),
                      // A group: open to anyone to join, or members only.
                      if (_channel.type == 'group')
                        PopupMenuItem(
                          value: 'visibility',
                          child: ListTile(
                            leading: Icon(
                              _channel.isPrivate
                                  ? Icons.lock_outline
                                  : Icons.public,
                            ),
                            title: const Text('Visibility'),
                            subtitle: Text(
                              _channel.isPrivate
                                  ? 'Private: members only'
                                  : 'Public: anyone can join',
                            ),
                          ),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          leading: Icon(Icons.delete_outline),
                          title: Text('Delete channel'),
                        ),
                      ),
                    ],
                    if (_channel.isDm)
                      const PopupMenuItem(
                        value: 'hide',
                        child: ListTile(
                          leading: Icon(Icons.visibility_off_outlined),
                          title: Text('Hide conversation'),
                        ),
                      ),
                  ],
                ),
              ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: _error != null && _messages.isEmpty
                  ? Center(child: Text('Couldn\'t load messages.\n$_error'))
                  : _loading && _messages.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n.metrics.extentAfter < 400) _loadMore();
                        return false;
                      },
                      child: ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _messages.length + (_isThread ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (_isThread && i == _messages.length) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _MessageTile(
                                  m: _parent!,
                                  me: _me(ref),
                                  onLongPress: () => _menu(_parent!),
                                  onReact: (e) => _toggleReaction(_parent!, e),
                                ),
                                const Divider(),
                              ],
                            );
                          }
                          final m = _messages[i];
                          final prev = i + 1 < _messages.length
                              ? _messages[i + 1]
                              : null;
                          // Messages close together from one author group.
                          final grouped =
                              prev != null &&
                              prev.author == m.author &&
                              m.at.difference(prev.at).inMinutes < 5;
                          return _MessageTile(
                            m: m,
                            me: _me(ref),
                            compact: grouped,
                            onLongPress: () => _menu(m),
                            onReact: (e) => _toggleReaction(m, e),
                            onThread: _isThread ? null : () => _openThread(m),
                          );
                        },
                      ),
                    ),
            ),
            if (_pending.isNotEmpty || _uploading > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final f in _pending)
                      InputChip(
                        avatar: Icon(
                          f.isImage
                              ? Icons.image_outlined
                              : Icons.insert_drive_file_outlined,
                          size: 18,
                        ),
                        label: Text(f.name, overflow: TextOverflow.ellipsis),
                        deleteButtonTooltipMessage: 'Remove file',
                        onDeleted: () => setState(() => _pending.remove(f)),
                      ),
                    if (_uploading > 0)
                      const Chip(
                        avatar: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        label: Text('Uploading…'),
                      ),
                  ],
                ),
              ),
            Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Upload Files',
                    onPressed: _attach,
                    icon: const Icon(Icons.add),
                  ),
                  IconButton(
                    tooltip: 'Ask a model',
                    onPressed: _mention,
                    icon: const Icon(Icons.alternate_email),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 6,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: _isThread
                            ? 'Reply in thread'
                            : 'Message ${widget.channel.isDm ? title : '#$title'}',
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 14,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Voice Input',
                    onPressed: _dictate,
                    icon: const Icon(Icons.mic_none),
                  ),
                  IconButton(
                    tooltip: 'Send',
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.arrow_upward),
                    color: NexusColors.accent,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({
    required this.m,
    required this.me,
    required this.onLongPress,
    required this.onReact,
    this.onThread,
    this.compact = false,
  });

  final ChannelMessage m;
  final String? me;
  final VoidCallback onLongPress;
  final ValueChanged<String> onReact;
  final VoidCallback? onThread;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = context.nexus.muted;
    final scheme = Theme.of(context).colorScheme;
    final initial = m.author.isEmpty
        ? '?'
        : m.author.characters.first.toUpperCase();
    return InkWell(
      onLongPress: onLongPress,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, compact ? 2 : 10, 16, 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 44,
              child: compact
                  ? null
                  : CircleAvatar(
                      radius: 17,
                      backgroundColor: m.modelName != null
                          ? NexusColors.accent
                          : scheme.surfaceContainerHighest,
                      child: m.modelName != null
                          ? const Icon(
                              Icons.auto_awesome,
                              size: 16,
                              color: Colors.white,
                            )
                          : Text(initial),
                    ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!compact)
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            m.author,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _clock(context, m.at),
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                        if (m.pinned) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.push_pin, size: 13, color: muted),
                        ],
                      ],
                    ),
                  if (m.content.isEmpty && !m.done)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text('Thinking…', style: TextStyle(color: muted)),
                    )
                  else
                    MarkdownBlock(
                      data: showMentions(m.content),
                      selectable: false,
                      config: dark
                          ? MarkdownConfig.darkConfig
                          : MarkdownConfig.defaultConfig,
                    ),
                  if (m.files.isNotEmpty)
                    MessageAttachments(attachments: m.files, alignEnd: false),
                  if (m.reactions.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final r in m.reactions)
                          ActionChip(
                            visualDensity: VisualDensity.compact,
                            backgroundColor: r.userIds.contains(me)
                                ? NexusColors.accent.withValues(alpha: 0.2)
                                : null,
                            label: Text('${_emoji(r.name)} ${r.count}'),
                            onPressed: () => onReact(r.name),
                          ),
                      ],
                    ),
                  if (onThread != null && m.replyCount > 0)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: onThread,
                      icon: const Icon(Icons.forum_outlined, size: 16),
                      label: Text(
                        m.replyCount == 1
                            ? '1 reply'
                            : '${m.replyCount} replies',
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The web stores some reactions by shortcode.
  static String _emoji(String name) => switch (name) {
    'thumbsup' || '+1' => '👍',
    'heart' => '❤️',
    'joy' => '😂',
    'tada' => '🎉',
    'eyes' => '👀',
    'pray' => '🙏',
    'fire' => '🔥',
    _ => name,
  };
}
