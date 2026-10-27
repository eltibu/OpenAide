import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../terminal/terminal_api.dart';
import '../terminal/terminal_screen.dart';
import '../update/update_screen.dart';
import '../../core/theme.dart';
import 'chat_controller.dart';

/// The web UI's sidebar: search, pinned chats, folders, then the rest.
/// Long-press a chat to rename, pin, move, archive or delete it.
class ChatDrawer extends ConsumerStatefulWidget {
  const ChatDrawer({super.key});

  @override
  ConsumerState<ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends ConsumerState<ChatDrawer> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = text.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).value;
    final small = Theme.of(context).textTheme.titleSmall;
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Nexus',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontFamily: 'serif'),
                    ),
                  ),
                  IconButton(
                    tooltip: 'New folder',
                    icon: const Icon(Icons.create_new_folder_outlined),
                    onPressed: () => _newFolder(context, ref),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: TextField(
                controller: _search,
                onChanged: _onSearch,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search chats',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                  isDense: true,
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: const CircleAvatar(
                radius: 14,
                backgroundColor: NexusColors.accent,
                child: Icon(Icons.add, size: 18, color: Colors.white),
              ),
              title: const Text(
                'New chat',
                style: TextStyle(
                  color: NexusColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                ref.read(chatControllerProvider.notifier).newChat();
              },
            ),
            const _Places(),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async => refreshChatLists(ref.invalidate),
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: _query.isNotEmpty
                      ? _results(ref.watch(chatSearchProvider(_query)))
                      : [..._pinned(small), ..._folders(), ..._chats(small)],
                ),
              ),
            ),
            const Divider(height: 1),
            _Account(session: session),
          ],
        ),
      ),
    );
  }

  List<Widget> _results(AsyncValue<List<ChatSummary>> found) => found.when(
    data: (list) => list.isEmpty
        ? [const ListTile(title: Text('No chats match'))]
        : [for (final c in list) ChatTile(chat: c)],
    loading: () => [const _Loading()],
    error: (e, _) => [_LoadError(error: e)],
  );

  List<Widget> _pinned(TextStyle? style) {
    final pinned = ref.watch(pinnedChatsProvider).value ?? const [];
    if (pinned.isEmpty) return const [];
    return [
      _Header('Starred', style: style),
      for (final c in pinned) ChatTile(chat: c, pinned: true),
    ];
  }

  List<Widget> _folders() {
    final folders = ref.watch(foldersProvider).value ?? const [];
    return [
      for (final f in folders.where((f) => f.parentId == null))
        FolderTile(folder: f, all: folders),
    ];
  }

  List<Widget> _chats(TextStyle? style) {
    final pages = ref.watch(chatPagesProvider);
    return [
      _Header('Recents', style: style),
      ...ref
          .watch(chatListProvider)
          .when(
            data: (list) => [
              for (final c in list) ChatTile(chat: c),
              if (list.length >= pages * chatPageSize)
                TextButton(
                  onPressed: () => ref.read(chatPagesProvider.notifier).more(),
                  child: const Text('Load more'),
                ),
            ],
            loading: () => [const _Loading()],
            error: (e, _) => [_LoadError(error: e)],
          ),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text, {this.style});
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
    child: Text(text, style: style),
  );
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Center(child: CircularProgressIndicator()),
  );
}

class _LoadError extends ConsumerWidget {
  const _LoadError({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    title: const Text('Could not load chats'),
    subtitle: Text('$error'),
    trailing: const Icon(Icons.refresh),
    onTap: () => refreshChatLists(ref.invalidate),
  );
}

/// A folder with its subfolders and chats, opened on tap.
class FolderTile extends ConsumerStatefulWidget {
  const FolderTile({super.key, required this.folder, required this.all});
  final Folder folder;
  final List<Folder> all;

  @override
  ConsumerState<FolderTile> createState() => _FolderTileState();
}

class _FolderTileState extends ConsumerState<FolderTile> {
  bool _open = false;
  int _pages = 1;

  @override
  Widget build(BuildContext context) {
    final f = widget.folder;
    final children = widget.all.where((c) => c.parentId == f.id);
    return ExpansionTile(
      dense: true,
      shape: const Border(),
      leading: Icon(_open ? Icons.folder_open : Icons.folder_outlined),
      title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      onExpansionChanged: (open) => setState(() => _open = open),
      trailing: PopupMenuButton<String>(
        tooltip: 'Folder options',
        icon: const Icon(Icons.more_vert, size: 20),
        onSelected: (action) => _folderAction(context, action),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'sub', child: Text('New folder inside')),
          PopupMenuItem(value: 'delete', child: Text('Delete folder')),
        ],
      ),
      childrenPadding: const EdgeInsets.only(left: 12),
      children: [
        for (final c in children) FolderTile(folder: c, all: widget.all),
        if (_open)
          ...ref
              .watch(folderChatsProvider((f.id, _pages)))
              .when(
                data: (list) => [
                  for (final c in list) ChatTile(chat: c),
                  if (list.length >= _pages * folderPageSize)
                    TextButton(
                      onPressed: () => setState(() => _pages++),
                      child: const Text('Show more'),
                    ),
                  if (list.isEmpty && children.isEmpty)
                    const ListTile(dense: true, title: Text('Empty')),
                ],
                loading: () => [const _Loading()],
                error: (e, _) => [_LoadError(error: e)],
              ),
      ],
    );
  }

  Future<void> _folderAction(BuildContext context, String action) async {
    final client = ref.read(clientProvider);
    final f = widget.folder;
    try {
      switch (action) {
        case 'rename':
          final name = await _askText(context, 'Rename folder', f.name);
          if (name == null) return;
          await client.renameFolder(f.id, name);
        case 'sub':
          final name = await _askText(context, 'New folder', '');
          if (name == null) return;
          await client.createFolder(name, parentId: f.id);
        case 'delete':
          final ok = await _confirm(
            context,
            'Delete "${f.name}"?',
            'The folder goes away; its chats move back to your chat list.',
          );
          if (!ok) return;
          await client.deleteFolder(f.id);
      }
      refreshChatLists(ref.invalidate);
    } catch (e) {
      if (context.mounted) _showError(context, e);
    }
  }
}

/// One chat in the list. Long-press for rename, pin, move, archive, delete.
class ChatTile extends ConsumerWidget {
  const ChatTile({super.key, required this.chat, this.pinned});
  final ChatSummary chat;

  /// Known from the section it's in; looked up for search results.
  final bool? pinned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(chatControllerProvider.select((s) => s.chat?.id));
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      visualDensity: VisualDensity.compact,
      selected: chat.id == current,
      selectedColor: scheme.onSurface,
      selectedTileColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () {
        Navigator.pop(context);
        ref.read(chatControllerProvider.notifier).open(chat.id);
      },
      onLongPress: () => _actions(context, ref),
    );
  }

  Future<void> _actions(BuildContext context, WidgetRef ref) async {
    final isPinned =
        pinned ??
        (ref.read(pinnedChatsProvider).value ?? const []).any(
          (c) => c.id == chat.id,
        );
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                chat.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final (value, icon, label) in [
              ('rename', Icons.edit_outlined, 'Rename'),
              (
                'pin',
                isPinned ? Icons.star : Icons.star_outline,
                isPinned ? 'Unstar' : 'Star',
              ),
              ('move', Icons.drive_file_move_outline, 'Move to folder'),
              ('archive', Icons.archive_outlined, 'Archive'),
              ('delete', Icons.delete_outline, 'Delete'),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    final controller = ref.read(chatControllerProvider.notifier);
    try {
      switch (action) {
        case 'rename':
          final title = await _askText(context, 'Rename chat', chat.title);
          if (title != null) await controller.renameChat(chat.id, title);
        case 'pin':
          await controller.togglePin(chat.id);
        case 'move':
          final folders = await ref.read(foldersProvider.future);
          if (!context.mounted) return;
          final target = await _pickFolder(context, folders);
          if (target != null) {
            await controller.moveChat(chat.id, target.isEmpty ? null : target);
          }
        case 'archive':
          await controller.archiveChat(chat.id);
        case 'delete':
          final ok = await _confirm(
            context,
            'Delete this chat?',
            '"${chat.title}" is deleted from the server for good.',
          );
          if (ok) await controller.deleteChat(chat.id);
      }
    } catch (e) {
      if (context.mounted) _showError(context, e);
    }
  }
}

Future<void> _newFolder(BuildContext context, WidgetRef ref) async {
  final name = await _askText(context, 'New folder', '');
  if (name == null) return;
  try {
    await ref.read(clientProvider).createFolder(name);
    refreshChatLists(ref.invalidate);
  } catch (e) {
    if (context.mounted) _showError(context, e);
  }
}

/// Returns a folder id, '' for "no folder", or null if cancelled.
Future<String?> _pickFolder(BuildContext context, List<Folder> folders) {
  // Depth-first, so subfolders sit under their parent.
  final ordered = <(Folder, int)>[];
  void add(String? parent, int depth) {
    for (final f in folders.where((f) => f.parentId == parent)) {
      ordered.add((f, depth));
      add(f.id, depth + 1);
    }
  }

  add(null, 0);
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Move to folder'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, ''),
          child: const Text('No folder'),
        ),
        for (final (f, depth) in ordered)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, f.id),
            child: Padding(
              padding: EdgeInsets.only(left: 16.0 * depth),
              child: Row(
                children: [
                  const Icon(Icons.folder_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(f.name)),
                ],
              ),
            ),
          ),
        if (ordered.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Text('No folders yet. Make one with the folder button.'),
          ),
      ],
    ),
  );
}

Future<String?> _askText(
  BuildContext context,
  String title,
  String initial,
) async {
  final text = TextEditingController(text: initial);
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: text,
        autofocus: true,
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, text.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  text.dispose();
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;

void _showError(BuildContext context, Object e) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));

/// You, at the bottom of the menu, with app updates and sign-out.
/// The rest of the server beside chats: its terminals and files for now.
class _Places extends ConsumerWidget {
  const _Places();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(terminalServersProvider).value ?? const [];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final server in servers) ...[
          _place(context, Icons.terminal, server.name, server, false),
          _place(context, Icons.folder_outlined, 'Files', server, true),
        ],
      ],
    );
  }

  Widget _place(
    BuildContext context,
    IconData icon,
    String label,
    TerminalServer server,
    bool files,
  ) => ListTile(
    dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
    leading: Icon(icon, size: 22),
    title: Text(label, style: const TextStyle(fontSize: 15)),
    onTap: () {
      Navigator.pop(context);
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => TerminalScreen(server: server, startInFiles: files),
        ),
      );
    },
  );
}

class _Account extends ConsumerWidget {
  const _Account({required this.session});
  final Session? session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = session?.userName ?? '';
    final initials = name.trim().isEmpty
        ? '?'
        : name
              .trim()
              .split(RegExp(r'\s+'))
              .take(2)
              .map((w) => w[0].toUpperCase())
              .join();
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Text(initials),
      ),
      title: Text(name.isEmpty ? 'Account' : name),
      subtitle: Text(
        Uri.tryParse(session?.serverUrl ?? '')?.host ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Settings',
        icon: const Icon(Icons.settings_outlined),
        onSelected: (choice) {
          if (choice == 'updates') {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const UpdateScreen()),
            );
          } else if (choice == 'signout') {
            ref.read(sessionProvider.notifier).signOut();
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'updates', child: Text('App updates')),
          PopupMenuItem(value: 'signout', child: Text('Sign out')),
        ],
      ),
    );
  }
}
