import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../admin/admin_screen.dart';
import '../automations/automations_screen.dart';
import '../calendar/calendar_screen.dart';
import '../channels/channels_screen.dart';
import '../notes/notes_screen.dart';
import '../playground/playground_screen.dart';
import '../email/email_screen.dart';
import '../studio/record_notes.dart';
import '../studio/studio_screen.dart';
import '../terminal/terminal_screen.dart';
import '../workspace/knowledge_screen.dart';
import '../workspace/models_screen.dart';
import '../workspace/prompts_screen.dart';
import '../workspace/tools_skills.dart';
import '../../core/theme.dart';
import '../settings/settings_screen.dart';
import 'chat_controller.dart';
import 'chat_extras.dart';
import 'folder_settings.dart';

/// The web UI's sidebar: search, pinned chats, folders, then the rest.
/// Long-press a chat to rename, pin, move, archive or delete it.
class ChatDrawer extends ConsumerStatefulWidget {
  const ChatDrawer({super.key, this.docked = false});

  /// Shown as a panel beside the chat (wide screens) instead of sliding in.
  final bool docked;

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
    final picking = ref.watch(chatSelectionProvider);
    final small = Theme.of(context).textTheme.titleSmall;
    final content = SafeArea(
      child: Column(
        children: [
          if (picking != null)
            _SelectionBar(ids: picking)
          else
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
              closeDrawer(context);
              ref.read(chatControllerProvider.notifier).newChat();
            },
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => refreshChatLists(ref.invalidate),
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: _query.isNotEmpty
                    ? _results(ref.watch(chatSearchProvider(_query)))
                    : [
                        const _Places(),
                        ..._pinned(small),
                        ..._folders(),
                        ..._chats(small),
                      ],
              ),
            ),
          ),
          const Divider(height: 1),
          _Account(session: session),
        ],
      ),
    );
    if (!widget.docked) return Drawer(child: content);
    return Material(
      color:
          Theme.of(context).drawerTheme.backgroundColor ??
          Theme.of(context).colorScheme.surfaceContainerLow,
      child: content,
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
          PopupMenuItem(value: 'edit', child: Text('Folder settings')),
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
        case 'edit':
          await editFolder(context, f.id);
          return;
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

/// Chats picked to archive, move or delete together; null when not picking.
class ChatSelection extends Notifier<Set<String>?> {
  @override
  Set<String>? build() => null;

  void start(String id) => state = {id};

  void toggle(String id) {
    final now = {...?state};
    now.contains(id) ? now.remove(id) : now.add(id);
    state = now.isEmpty ? null : now;
  }

  void clear() => state = null;
}

final chatSelectionProvider = NotifierProvider<ChatSelection, Set<String>?>(
  ChatSelection.new,
);

/// One chat in the list. Long-press for rename, pin, move, archive, delete.
class ChatTile extends ConsumerWidget {
  const ChatTile({super.key, required this.chat, this.pinned});
  final ChatSummary chat;

  /// Known from the section it's in; looked up for search results.
  final bool? pinned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(chatControllerProvider.select((s) => s.chat?.id));
    final picking = ref.watch(chatSelectionProvider);
    final scheme = Theme.of(context).colorScheme;
    if (picking != null) {
      final on = picking.contains(chat.id);
      return ListTile(
        visualDensity: VisualDensity.compact,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        leading: Icon(
          on ? Icons.check_circle : Icons.radio_button_unchecked,
          color: on ? NexusColors.accent : scheme.onSurfaceVariant,
        ),
        title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => ref.read(chatSelectionProvider.notifier).toggle(chat.id),
      );
    }
    return ListTile(
      visualDensity: VisualDensity.compact,
      selected: chat.id == current,
      selectedColor: scheme.onSurface,
      selectedTileColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () {
        closeDrawer(context);
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
      isScrollControlled: true,
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
              ('tags', Icons.sell_outlined, 'Tags'),
              ('share', Icons.ios_share, 'Share'),
              ('export', Icons.download_outlined, 'Export'),
              ('clone', Icons.copy_all_outlined, 'Clone'),
              ('select', Icons.checklist, 'Select chats'),
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
        case 'tags':
          await editTags(context, chat.id);
        case 'share':
          await shareChat(context, chat.id);
        case 'export':
          final kind = await showModalBottomSheet<String>(
            context: context,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (value, label) in [
                    ('json', 'Chat file (.json), to import again'),
                    ('txt', 'Plain text (.txt)'),
                    ('pdf', 'PDF document (.pdf)'),
                  ])
                    ListTile(
                      title: Text(label),
                      onTap: () => Navigator.pop(context, value),
                    ),
                ],
              ),
            ),
          );
          if (kind != null && context.mounted) {
            await exportChat(context, ref, chat.id, kind);
          }
        case 'select':
          ref.read(chatSelectionProvider.notifier).start(chat.id);
        case 'clone':
          closeDrawer(context);
          await cloneChat(ref, chat.id, chat.title);
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

/// What to do with the picked chats, in place of the drawer's title.
class _SelectionBar extends ConsumerWidget {
  const _SelectionBar({required this.ids});
  final Set<String> ids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(chatControllerProvider.notifier);
    final selection = ref.read(chatSelectionProvider.notifier);
    Future<void> each(Future<void> Function(String id) action) async {
      try {
        for (final id in ids.toList()) {
          await action(id);
        }
        selection.clear();
      } catch (e) {
        if (context.mounted) _showError(context, e);
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Done',
            icon: const Icon(Icons.close),
            onPressed: selection.clear,
          ),
          Expanded(
            child: Text(
              '${ids.length} selected',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: 'Move to folder',
            icon: const Icon(Icons.drive_file_move_outline),
            onPressed: () async {
              final folders = await ref.read(foldersProvider.future);
              if (!context.mounted) return;
              final target = await _pickFolder(context, folders);
              if (target == null) return;
              await each(
                (id) => controller.moveChat(id, target.isEmpty ? null : target),
              );
            },
          ),
          IconButton(
            tooltip: 'Archive',
            icon: const Icon(Icons.archive_outlined),
            onPressed: () => each(controller.archiveChat),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final ok = await _confirm(
                context,
                'Delete ${ids.length} chats?',
                'They are deleted from the server for good.',
              );
              if (ok) await each(controller.deleteChat);
            },
          ),
        ],
      ),
    );
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
/// Channels the person is in, for the drawer.
final channelsProvider = FutureProvider<List<({String id, String name})>>((
  ref,
) async {
  try {
    final res = await ref
        .watch(clientProvider)
        .send('GET', '/api/v1/channels/');
    return [
      for (final c in (res as List? ?? const []).whereType<Map>())
        (id: '${c['id']}', name: '${c['name'] ?? c['id']}'),
    ];
  } catch (_) {
    return const [];
  }
});

/// The rest of the server beside chats: its terminals and files first, then
/// every other section of the web UI (opened as the server's own pages until
/// each one is native).
class _Places extends ConsumerWidget {
  const _Places();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(terminalServersProvider).value ?? const [];
    final features =
        (ref.watch(serverConfigProvider).value?['features'] as Map?) ??
        const {};
    final admin = ref.watch(sessionProvider).value?.user?['role'] == 'admin';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final server in servers) ...[
          _tile(
            context,
            Icons.terminal,
            server.name,
            () => TerminalScreen(server: server, startInFiles: false),
          ),
          _tile(
            context,
            Icons.folder_outlined,
            'Files',
            () => TerminalScreen(server: server, startInFiles: true),
          ),
        ],
        _tile(
          context,
          Icons.grid_view,
          'Workspace',
          () => WorkspaceScreen(
            sections: [
              (
                Icons.auto_awesome_outlined,
                'Models',
                'Your own models: instructions, knowledge, tools',
                () => const ModelsScreen(),
              ),
              (
                Icons.menu_book_outlined,
                'Knowledge',
                'Documents models can search',
                () => const KnowledgeScreen(),
              ),
              (
                Icons.bolt,
                'Prompts',
                'Saved prompts you type with /',
                () => const PromptsScreen(),
              ),
              (
                Icons.build_outlined,
                'Tools',
                'What models can do, and their settings',
                () => const ToolsScreen(),
              ),
              (
                Icons.psychology_outlined,
                'Skills',
                'Know-how models can use',
                () => const SkillsScreen(),
              ),
            ],
          ),
        ),
        if (features['enable_channels'] == true)
          _tile(context, Icons.tag, 'Channels', () => const ChannelsScreen()),
        if (features['enable_notes'] == true)
          _tile(
            context,
            Icons.sticky_note_2_outlined,
            'Notes',
            () => const NotesScreen(),
          ),
        if (features['enable_calendar'] == true)
          _tile(
            context,
            Icons.calendar_month_outlined,
            'Calendar',
            () => const CalendarScreen(),
          ),
        if (features['enable_automations'] == true)
          _tile(
            context,
            Icons.schedule,
            'Automations',
            () => const AutomationsScreen(),
          ),
        _tile(
          context,
          Icons.edit_document,
          'Studio',
          () => const StudioScreen(),
        ),
        _tile(
          context,
          Icons.mic_none,
          'Record notes',
          () => const RecordNotesScreen(),
        ),
        _tile(context, Icons.mail_outline, 'Email', () => const EmailScreen()),
        if (admin) ...[
          _tile(
            context,
            Icons.code,
            'Playground',
            () => const PlaygroundScreen(),
          ),
          _tile(
            context,
            Icons.admin_panel_settings_outlined,
            'Admin Panel',
            () => const AdminScreen(),
          ),
        ],
      ],
    );
  }

  Widget _tile(
    BuildContext context,
    IconData icon,
    String label,
    Widget Function() page, {
    bool indent = false,
  }) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.only(left: indent ? 40 : 24, right: 24),
    leading: Icon(icon, size: 22),
    title: Text(label, style: const TextStyle(fontSize: 15)),
    onTap: () {
      closeDrawer(context);
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page()));
    },
  );
}

class _Account extends ConsumerWidget {
  const _Account({required this.session});
  final Session? session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider).value ?? session?.user;
    final name = '${me?['name'] ?? session?.userName ?? ''}';
    void settings() {
      closeDrawer(context);
      Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      );
    }

    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      leading: Avatar(user: me),
      title: Text(name.isEmpty ? 'Account' : name),
      subtitle: Text(
        Uri.tryParse(session?.serverUrl ?? '')?.host ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: settings,
      trailing: IconButton(
        tooltip: 'Settings',
        icon: const Icon(Icons.settings_outlined),
        onPressed: settings,
      ),
    );
  }
}

/// Closes the chat list when it slid in over the chat; a docked one stays.
void closeDrawer(BuildContext context) {
  final scaffold = Scaffold.maybeOf(context);
  if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
}
