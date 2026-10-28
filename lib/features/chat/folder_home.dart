/// A new chat started in a folder, as the web's folder page: the folder's
/// icon (tap to change it) and name, its menu, and its chats and knowledge
/// under the greeting.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../../core/theme.dart';
import 'chat_controller.dart';
import 'emoji.dart';
import 'folder_settings.dart';
import '../../core/i18n/app_strings.dart';

/// The folder as the server has it: name, meta (icon) and data (files).
final folderDetailProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>(
      (ref, id) async =>
          ((await ref.watch(clientProvider).send('GET', '/api/v1/folders/$id'))
                  as Map)
              .cast<String, dynamic>(),
    );

/// The emoji for a folder's icon shortcode, or null for the plain folder.
String? folderEmoji(Map<String, dynamic>? folder) {
  final code = '${(folder?['meta'] as Map?)?['icon'] ?? ''}'.trim();
  if (code.isEmpty) return null;
  return emojiShortcodes.where((e) => e.$1 == code).firstOrNull?.$2;
}

class FolderHome extends ConsumerStatefulWidget {
  const FolderHome({super.key, required this.folder});
  final Folder folder;

  @override
  ConsumerState<FolderHome> createState() => _FolderHomeState();
}

class _FolderHomeState extends ConsumerState<FolderHome> {
  String _tab = 'chats';
  final _chats = <ChatSummary>[];
  int _page = 0;
  bool _more = true;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadChats();
  }

  @override
  void didUpdateWidget(FolderHome old) {
    super.didUpdateWidget(old);
    if (old.folder.id != widget.folder.id) {
      _chats.clear();
      _page = 0;
      _more = true;
      _loadChats();
    }
  }

  Future<void> _loadChats() async {
    if (_loading || !_more) return;
    setState(() => _loading = true);
    try {
      final list = await ref
          .read(clientProvider)
          .folderChats(widget.folder.id, page: _page + 1);
      _page++;
      _chats.addAll(list);
      _more = list.length >= 10;
    } catch (_) {
      _more = false;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickIcon(String? current) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: T(
                      'Change folder icon',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (current != null)
                    TextButton(
                      onPressed: () => Navigator.pop(context, ''),
                      child: const T('Remove'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                ),
                child: GridView.extent(
                  shrinkWrap: true,
                  maxCrossAxisExtent: 48,
                  children: [
                    for (final (code, emoji) in emojiShortcodes)
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => Navigator.pop(context, code),
                        child: Center(
                          child: Text(
                            emoji,
                            semanticsLabel: code,
                            style: const TextStyle(fontSize: 24),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(clientProvider)
          .send(
            'POST',
            '/api/v1/folders/${widget.folder.id}/update',
            body: {
              'meta': {'icon': picked},
            },
          );
      messenger.showSnackBar(
        const SnackBar(content: T('Folder updated successfully')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
    ref.invalidate(folderDetailProvider(widget.folder.id));
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.folder;
    final detail = ref.watch(folderDetailProvider(f.id)).value;
    final emoji = folderEmoji(detail);
    final files = [
      for (final x
          in ((detail?['data'] as Map?)?['files'] as List? ?? const [])
              .whereType<Map>())
        x,
    ];
    final muted = context.nexus.muted;
    final controller = ref.read(chatControllerProvider.notifier);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: tr('Change folder icon'),
                  onPressed: () => _pickIcon(emoji),
                  icon: emoji == null
                      ? const Icon(Icons.folder_outlined)
                      : Text(emoji, style: const TextStyle(fontSize: 22)),
                ),
                Expanded(
                  child: Text(
                    detail?['name'] as String? ?? f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: tr('Edit folder'),
                  icon: const Icon(Icons.tune),
                  onPressed: () async {
                    await editFolder(context, f.id);
                    ref
                      ..invalidate(folderDetailProvider(f.id))
                      ..invalidate(foldersProvider);
                  },
                ),
                IconButton(
                  tooltip: tr('Leave folder'),
                  icon: const Icon(Icons.close),
                  onPressed: () => controller.newChat(),
                ),
              ],
            ),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(value: 'chats', label: T('Chats')),
                ButtonSegment(
                  value: 'knowledge',
                  label: Text(
                    files.isEmpty ? 'Knowledge' : 'Knowledge (${files.length})',
                  ),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
            const SizedBox(height: 4),
            if (_tab == 'chats') ...[
              for (final c in _chats)
                ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.chat_bubble_outline,
                    size: 18,
                    color: muted,
                  ),
                  title: Text(
                    c.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => controller.open(c.id),
                ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_more)
                TextButton(onPressed: _loadChats, child: const T('Load more'))
              else if (_chats.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: T(
                    'No chats in this folder yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted),
                  ),
                ),
            ] else ...[
              for (final x in files)
                ListTile(
                  dense: true,
                  leading: Icon(
                    x['type'] == 'collection'
                        ? Icons.menu_book_outlined
                        : Icons.insert_drive_file_outlined,
                    size: 18,
                    color: muted,
                  ),
                  title: Text(
                    '${x['name'] ?? (x['meta'] as Map?)?['name'] ?? x['id']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  files.isEmpty
                      ? 'No knowledge yet. Add files in Edit folder; every '
                            'chat here can use them.'
                      : 'Every chat in this folder can use these.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
