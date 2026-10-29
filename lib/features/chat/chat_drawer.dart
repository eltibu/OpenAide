import 'search_everywhere.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../../core/models/model_info.dart';
import 'model_pins.dart';
import '../admin/admin_screen.dart';
import '../automations/automations_screen.dart';
import '../calendar/calendar_screen.dart';
import '../channels/channels_api.dart' show Channel;
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
import '../../core/widgets/nexus_logo.dart';
import '../settings/settings_screen.dart';
import 'chat_controller.dart';
import 'chat_extras.dart';
import 'chat_panel.dart' show showChatPanel;
import 'folder_settings.dart';
import 'shared_folders.dart';
import '../workspace/access_editor.dart' show editAccess;
import '../../core/i18n/app_strings.dart';

/// The web UI's sidebar: a short list of places at the top (new chat,
/// search, notes, workspace), then Channels, Folders and Chats as sections
/// that fold away, with chats grouped by when they were last used. The rest
/// of the server is in the menu on your name at the bottom.
/// Long-press a chat to rename, pin, move, archive or delete it.
class ChatDrawer extends ConsumerStatefulWidget {
  const ChatDrawer({super.key, this.docked = false});

  /// Shown as a panel beside the chat (wide screens) instead of sliding in.
  final bool docked;

  @override
  ConsumerState<ChatDrawer> createState() => _ChatDrawerState();
}

/// Sections of the sidebar folded away; kept while the app runs, so the
/// sidebar opens as you left it.
class _Folded extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String section) => state = state.contains(section)
      ? ({...state}..remove(section))
      : {...state, section};
}

final _foldedProvider = NotifierProvider<_Folded, Set<String>>(_Folded.new);

class _ChatDrawerState extends ConsumerState<ChatDrawer> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  bool _searching = false;

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

  void _stopSearch() {
    _search.clear();
    setState(() {
      _query = '';
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).value;
    final picking = ref.watch(chatSelectionProvider);
    final features =
        (ref.watch(serverConfigProvider).value?['features'] as Map?) ??
        const {};
    final content = SafeArea(
      child: Column(
        children: [
          if (picking != null)
            _SelectionBar(ids: picking)
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 12, 6),
              child: Row(
                children: [
                  const NexusLogo(size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: T(
                      'OpenAide',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontFamily: 'serif'),
                    ),
                  ),
                ],
              ),
            ),
          _NavRow(
            icon: Icons.edit_outlined,
            label: 'New chat',
            onTap: () {
              closeDrawer(context);
              ref.read(chatControllerProvider.notifier).newChat();
            },
          ),
          if (_searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
              child: TextField(
                controller: _search,
                autofocus: true,
                onChanged: _onSearch,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: tr('Search chats'),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: IconButton(
                    tooltip: tr('Close search'),
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: _stopSearch,
                  ),
                  isDense: true,
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          if (_searching)
            _NavRow(
              icon: Icons.travel_explore,
              label: 'Search everywhere',
              onTap: () => openPlace(
                context,
                (_) => SearchEverywhereScreen(query: _search.text),
              ),
            )
          else
            _NavRow(
              icon: Icons.search,
              label: 'Search',
              onTap: () => setState(() => _searching = true),
            ),
          if (features['enable_notes'] == true)
            _NavRow(
              icon: Icons.sticky_note_2_outlined,
              label: 'Notes',
              onTap: () => openPlace(context, (_) => const NotesScreen()),
            ),
          _NavRow(
            icon: Icons.grid_view,
            label: 'Workspace',
            onTap: () => openPlace(context, (_) => workspaceScreen()),
          ),
          _NavRow(
            icon: Icons.edit_document,
            label: 'Studio',
            onTap: () => openPlace(context, (_) => const StudioScreen()),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                refreshChatLists(ref.invalidate);
                ref.invalidate(sharedFoldersProvider);
                ref.invalidate(channelListProvider);
              },
              // Slim rows, as on the web, so more chats fit.
              child: ListTileTheme(
                data: ListTileTheme.of(context).copyWith(
                  dense: true,
                  minTileHeight: 38,
                  minVerticalPadding: 0,
                  visualDensity: VisualDensity.compact,
                  titleTextStyle: Theme.of(context).textTheme.bodyMedium,
                ),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  children: _query.isNotEmpty
                      ? _results(ref.watch(chatSearchProvider(_query)))
                      : [
                          ..._pinnedModels(),
                          if (features['enable_channels'] == true)
                            ..._channels(),
                          ..._folders(),
                          ..._shared(),
                          ..._pinned(),
                          ..._chats(),
                        ],
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          _Account(session: session),
        ],
      ),
    );
    if (!widget.docked) {
      // Narrower than the default, so the chat still shows beside it.
      return Drawer(width: 300, child: content);
    }
    return Material(
      color:
          Theme.of(context).drawerTheme.backgroundColor ??
          Theme.of(context).colorScheme.surfaceContainerLow,
      child: content,
    );
  }

  bool _open(String section) => !ref.watch(_foldedProvider).contains(section);

  _Section _section(
    String name, {
    VoidCallback? onAdd,
    String? addTip,
    IconData addIcon = Icons.add,
  }) => _Section(
    name,
    open: _open(name),
    onToggle: () => ref.read(_foldedProvider.notifier).toggle(name),
    onAdd: onAdd,
    addTip: addTip,
    addIcon: addIcon,
  );

  List<Widget> _results(AsyncValue<List<ChatSummary>> found) => found.when(
    data: (list) => list.isEmpty
        ? [const ListTile(title: T('No chats match'))]
        : [for (final c in list) ChatTile(chat: c)],
    loading: () => [const _Loading()],
    error: (e, _) => [_LoadError(error: e)],
  );

  List<Widget> _channels() {
    final list = ref.watch(channelListProvider).value ?? const <Channel>[];
    return [
      _section(
        'Channels',
        addTip: 'All channels',
        onAdd: () => openPlace(context, (_) => const ChannelsScreen()),
      ),
      if (_open('Channels'))
        for (final c in list)
          _SmallTile(
            icon: c.type == 'dm' ? Icons.person_outline : Icons.tag,
            label: c.name,
            badge: c.unread,
            onTap: () async {
              // The menu closes when the channel opens, so its ref is gone
              // by the time the channel is left; the container isn't.
              final container = ProviderScope.containerOf(
                context,
                listen: false,
              );
              await openPlace(context, (_) => ChannelScreen(channel: c));
              container.invalidate(channelListProvider);
            },
          ),
    ];
  }

  /// Models kept in the sidebar: tap for a new chat with one, hold to
  /// take it off.
  List<Widget> _pinnedModels() {
    final models = ref.watch(visiblePinnedModelsProvider);
    if (models.isEmpty) return const [];
    return [
      _section('Models'),
      if (_open('Models'))
        for (final m in models)
          GestureDetector(
            onLongPress: () => _unpinModel(m),
            child: _SmallTile(
              icon: Icons.auto_awesome_outlined,
              label: m.name,
              onTap: () {
                ref.read(chatControllerProvider.notifier)
                  ..newChat()
                  ..selectModel(m.id);
                closeDrawer(context);
              },
            ),
          ),
    ];
  }

  Future<void> _unpinModel(ModelInfo m) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.push_pin_outlined),
          title: Text('Hide ${m.name} from Sidebar'),
          onTap: () => Navigator.pop(c, true),
        ),
      ),
    );
    if (ok == true) await togglePinnedModel(ref, m.id);
  }

  List<Widget> _pinned() {
    final pinned = ref.watch(pinnedChatsProvider).value ?? const [];
    if (pinned.isEmpty) return const [];
    return [
      _section('Starred'),
      if (_open('Starred'))
        for (final c in pinned) ChatTile(chat: c, pinned: true),
    ];
  }

  List<Widget> _folders() {
    final folders = ref.watch(foldersProvider).value ?? const [];
    return [
      _section(
        'Folders',
        addTip: 'New folder',
        onAdd: () => _newFolder(context, ref),
      ),
      if (_open('Folders'))
        for (final f in folders.where((f) => f.parentId == null))
          FolderTile(folder: f, all: folders),
    ];
  }

  /// Folders other people shared with you.
  List<Widget> _shared() {
    final shared = ref.watch(sharedFoldersProvider).value ?? const [];
    final ids = {for (final f in shared) f.id};
    final top = shared.where(
      (f) => f.parentId == null || !ids.contains(f.parentId),
    );
    if (top.isEmpty) return const [];
    return [
      _section('Shared with you'),
      if (_open('Shared with you'))
        for (final f in top)
          _SmallTile(
            icon: f.writable
                ? Icons.folder_shared_outlined
                : Icons.visibility_outlined,
            label: f.owner.isEmpty ? f.name : '${f.name} · ${f.owner}',
            onTap: () =>
                openPlace(context, (_) => SharedFolderScreen(folder: f)),
          ),
    ];
  }

  List<Widget> _chats() {
    final pages = ref.watch(chatPagesProvider);
    final unread = (ref.watch(chatListProvider).value ?? const []).any(
      (c) => c.unread,
    );
    return [
      _section(
        'Chats',
        addTip: 'Mark all as read',
        addIcon: Icons.done_all,
        onAdd: unread
            ? () async {
                try {
                  await ref
                      .read(clientProvider)
                      .send('POST', '/api/v1/chats/read');
                } catch (e) {
                  if (mounted) _showError(context, e);
                }
                refreshChatLists(ref.invalidate);
              }
            : null,
      ),
      if (_open('Chats'))
        ...ref
            .watch(chatListProvider)
            .when(
              data: (list) => [
                for (final (group, chats) in groupByWhen(
                  list,
                  DateTime.now(),
                )) ...[_When(group), for (final c in chats) ChatTile(chat: c)],
                if (list.length >= pages * chatPageSize)
                  TextButton(
                    onPressed: () =>
                        ref.read(chatPagesProvider.notifier).more(),
                    child: const T('Load more'),
                  ),
              ],
              loading: () => [const _Loading()],
              error: (e, _) => [_LoadError(error: e)],
            ),
    ];
  }
}

/// Chats in the web UI's groups: Today, Yesterday, Previous 7 days,
/// Previous 30 days, then by month. [chats] come newest first.
List<(String, List<ChatSummary>)> groupByWhen(
  List<ChatSummary> chats,
  DateTime now,
) {
  final today = DateTime(now.year, now.month, now.day);
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July', //
    'August', 'September', 'October', 'November', 'December',
  ];
  String label(DateTime t) {
    final day = DateTime(t.year, t.month, t.day);
    final days = today.difference(day).inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days < 7) return 'Previous 7 days';
    if (days < 30) return 'Previous 30 days';
    final month = months[t.month - 1];
    return t.year == now.year ? month : '$month ${t.year}';
  }

  final out = <(String, List<ChatSummary>)>[];
  for (final c in chats) {
    final l = label(c.updatedAt);
    if (out.isNotEmpty && out.last.$1 == l) {
      out.last.$2.add(c);
    } else {
      out.add((l, [c]));
    }
  }
  return out;
}

/// One of the places at the top of the sidebar.
class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(icon, size: 20),
            const SizedBox(width: 14),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 15))),
          ],
        ),
      ),
    ),
  );
}

/// A row inside a section (a channel).
class _SmallTile extends StatelessWidget {
  const _SmallTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge = 0,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: onTap,
    child: SizedBox(
      height: 36,
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(icon, size: 18, color: context.nexus.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (badge > 0) ...[
            Badge(label: Text('$badge')),
            const SizedBox(width: 12),
          ],
        ],
      ),
    ),
  );
}

/// A section's title: tap to fold it away, + to add to it.
class _Section extends StatelessWidget {
  const _Section(
    this.name, {
    required this.open,
    required this.onToggle,
    this.onAdd,
    this.addTip,
    this.addIcon = Icons.add,
  });
  final String name;
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback? onAdd;
  final String? addTip;
  final IconData addIcon;

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onToggle,
        child: SizedBox(
          height: 32,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Text(
                name,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: muted),
              ),
              Icon(
                open ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: muted,
              ),
              const Spacer(),
              if (onAdd != null)
                IconButton(
                  tooltip: addTip,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: muted,
                  icon: Icon(addIcon),
                  onPressed: onAdd,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Today, Yesterday... above the chats from then.
class _When extends StatelessWidget {
  const _When(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: context.nexus.muted),
    ),
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
    title: const T('Could not load chats'),
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
      title: Row(
        children: [
          Flexible(
            child: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (f.unread > 0) ...[
            const SizedBox(width: 6),
            Badge(label: Text('${f.unread}')),
          ],
        ],
      ),
      onExpansionChanged: (open) => setState(() => _open = open),
      trailing: PopupMenuButton<String>(
        tooltip: tr('Folder options'),
        icon: const Icon(Icons.more_vert, size: 20),
        onSelected: (action) => _folderAction(context, action),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'new', child: T('New Chat')),
          if (f.unread > 0)
            const PopupMenuItem(value: 'read', child: T('Mark all as read')),
          const PopupMenuItem(value: 'edit', child: T('Folder settings')),
          const PopupMenuItem(value: 'share', child: T('Share')),
          const PopupMenuItem(value: 'rename', child: T('Rename')),
          const PopupMenuItem(value: 'sub', child: T('New folder inside')),
          const PopupMenuItem(value: 'export', child: T('Export')),
          const PopupMenuItem(value: 'delete', child: T('Delete folder')),
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
                      child: const T('Show more'),
                    ),
                  if (list.isEmpty && children.isEmpty)
                    const ListTile(dense: true, title: T('Empty')),
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
        case 'new':
          ref
              .read(chatControllerProvider.notifier)
              .newChat(temporary: false, folderId: f.id);
          closeDrawer(context);
          return;
        case 'read':
          await client.send('POST', '/api/v1/folders/${f.id}/read');
        case 'export':
          final chats = await client.send(
            'GET',
            '/api/v1/chats/folder/${f.id}',
          );
          final name =
              'folder-${f.name}-export-${DateTime.now().millisecondsSinceEpoch}'
              '.json';
          await FilePicker.saveFile(
            fileName: name,
            bytes: Uint8List.fromList(utf8.encode(jsonEncode(chats))),
            mimeType: 'application/json',
          );
          return;
        case 'edit':
          await editFolder(context, f.id);
          return;
        case 'share':
          await editAccess(
            context,
            ref,
            kind: 'folder',
            id: f.id,
            name: f.name,
          );
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
      title: Text(
        chat.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: chat.unread && chat.id != current
            ? const TextStyle(fontWeight: FontWeight.w600)
            : null,
      ),
      trailing: chat.unread && chat.id != current
          ? const Icon(Icons.circle, size: 8, color: NexusColors.accent)
          : null,
      onTap: () {
        closeDrawer(context);
        ref.read(chatControllerProvider.notifier).open(chat.id);
      },
      onLongPress: () => showChatActions(context, ref, chat, pinned: pinned),
    );
  }
}

/// A chat's actions: rename, star, move, tags, share, export, clone,
/// archive, delete. From the chat list (long-press) or the chat's title in
/// the top bar ([inList] false), as the web's chat menus.
Future<void> showChatActions(
  BuildContext context,
  WidgetRef ref,
  ChatSummary chat, {
  bool? pinned,
  bool inList = true,
}) async {
  final isPinned =
      pinned ??
      (ref.read(pinnedChatsProvider).value ?? const []).any(
        (c) => c.id == chat.id,
      );
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    // Scrolls when the screen is short (a folded phone held sideways).
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
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
              if (!chat.unread)
                ('unread', Icons.mark_chat_unread_outlined, 'Mark as unread'),
              ('share', Icons.ios_share, 'Share'),
              ('export', Icons.download_outlined, 'Export'),
              ('clone', Icons.copy_all_outlined, 'Clone'),
              if (inList) ('select', Icons.checklist, 'Select chats'),
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
    ),
  );
  if (action == null || !context.mounted) return;
  final controller = ref.read(chatControllerProvider.notifier);
  try {
    switch (action) {
      case 'unread':
        await ref
            .read(clientProvider)
            .send('POST', '/api/v1/chats/${chat.id}/unread');
        refreshChatLists(ref.invalidate);
      case 'rename':
        final title = await _askText(
          context,
          'Rename chat',
          chat.title,
          generate: () => generateChatTitle(ref.read(clientProvider), chat.id),
        );
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
            tooltip: tr('Done'),
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
            tooltip: tr('Move to folder'),
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
            tooltip: tr('Archive'),
            icon: const Icon(Icons.archive_outlined),
            onPressed: () => each(controller.archiveChat),
          ),
          IconButton(
            tooltip: tr('Delete'),
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
      title: const T('Move to folder'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, ''),
          child: const T('No folder'),
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
            child: T('No folders yet. Make one with the folder button.'),
          ),
      ],
    ),
  );
}

Future<String?> _askText(
  BuildContext context,
  String title,
  String initial, {
  Future<String?> Function()? generate,
}) async {
  final text = TextEditingController(text: initial);
  var busy = false;
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: StatefulBuilder(
        builder: (context, setState) => TextField(
          controller: text,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(context, v),
          decoration: InputDecoration(
            suffixIcon: generate == null
                ? null
                : busy
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: tr('Generate'),
                    icon: const Icon(Icons.auto_awesome_outlined),
                    onPressed: () async {
                      setState(() => busy = true);
                      try {
                        final t = await generate();
                        if (t != null) text.text = t;
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Couldn't generate: $e")),
                          );
                        }
                      }
                      if (context.mounted) setState(() => busy = false);
                    },
                  ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const T('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, text.text),
          child: const T('Save'),
        ),
      ],
    ),
  );
  // Not disposed: the dialog's text field still builds while it closes.
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
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const T('Delete'),
          ),
        ],
      ),
    ) ??
    false;

void _showError(BuildContext context, Object e) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));

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

/// Opens one of the server's sections over the chat, closing the sidebar
/// first when it slid in.
Future<void> openPlace(BuildContext context, WidgetBuilder page) {
  final navigator = Navigator.of(context);
  closeDrawer(context);
  return navigator.push(MaterialPageRoute<void>(builder: page));
}

/// The web UI's Workspace: models, knowledge, prompts, tools and skills.
Widget workspaceScreen() => WorkspaceScreen(
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
);

final _menuItem = MenuItemButton.styleFrom(
  minimumSize: const Size(200, 40),
  visualDensity: VisualDensity.compact,
);

/// Who is using the server now, and the models running, as the web's
/// account menu shows them (admins, or everyone when the server allows).
final activeUsageProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) async =>
      ((await ref.watch(clientProvider).send('GET', '/api/usage')) as Map)
          .cast<String, dynamic>(),
);

/// "2 active users", and "Running: a, b" when models are answering.
String activeUsersText(Map<String, dynamic> usage) {
  final n = (usage['user_count'] as num?)?.toInt() ?? 0;
  final running = [
    for (final m in (usage['model_ids'] as List? ?? const [])) '$m',
  ];
  return [
    '$n active ${n == 1 ? 'user' : 'users'}',
    if (running.isNotEmpty) 'Running: ${running.join(', ')}',
  ].join(' · ');
}

/// You, at the bottom of the sidebar. Tap for the web UI's menu: the
/// server's other sections, Settings and Sign out.
class _Account extends ConsumerWidget {
  const _Account({required this.session});
  final Session? session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider).value ?? session?.user;
    final name = '${me?['name'] ?? session?.userName ?? ''}';
    final servers = ref.watch(allTerminalsProvider).value ?? const [];
    final features =
        (ref.watch(serverConfigProvider).value?['features'] as Map?) ??
        const {};
    final admin = me?['role'] == 'admin' || session?.user?['role'] == 'admin';

    MenuItemButton item(IconData icon, String label, WidgetBuilder page) =>
        MenuItemButton(
          style: _menuItem,
          leadingIcon: Icon(icon, size: 20),
          onPressed: () => openPlace(context, page),
          child: Text(label),
        );

    final showActive =
        admin || features['enable_public_active_users_count'] == true;
    final usage = showActive ? ref.watch(activeUsageProvider).value : null;

    return MenuAnchor(
      alignmentOffset: const Offset(12, 0),
      onOpen: showActive ? () => ref.invalidate(activeUsageProvider) : null,
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
      ),
      menuChildren: [
        if (usage != null && ((usage['user_count'] as num?) ?? 0) > 0) ...[
          MenuItemButton(
            style: _menuItem,
            leadingIcon: const Icon(
              Icons.circle,
              size: 10,
              color: Colors.green,
            ),
            onPressed: null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Text(activeUsersText(usage)),
            ),
          ),
          const Divider(height: 8),
        ],
        item(Icons.grid_view, 'Workspace', (_) => workspaceScreen()),
        if (features['enable_notes'] == true)
          item(
            Icons.sticky_note_2_outlined,
            'Notes',
            (_) => const NotesScreen(),
          ),
        if (features['enable_calendar'] == true)
          item(
            Icons.calendar_month_outlined,
            'Calendar',
            (_) => const CalendarScreen(),
          ),
        if (features['enable_automations'] == true)
          item(Icons.schedule, 'Automations', (_) => const AutomationsScreen()),
        if (features['enable_channels'] == true)
          item(Icons.tag, 'Channels', (_) => const ChannelsScreen()),
        const Divider(height: 8),
        item(Icons.edit_document, 'Studio', (_) => const StudioScreen()),
        item(Icons.mic_none, 'Record notes', (_) => const RecordNotesScreen()),
        item(Icons.mail_outline, 'Email', (_) => const EmailScreen()),
        // In the chat's side drawer, as on the web, not a page of its own.
        for (final server in servers) ...[
          MenuItemButton(
            style: _menuItem,
            leadingIcon: const Icon(Icons.terminal, size: 20),
            onPressed: () => showChatPanel(
              context,
              tab: 1,
              serverId: server.id,
              files: false,
            ),
            child: Text(server.name),
          ),
          MenuItemButton(
            style: _menuItem,
            leadingIcon: const Icon(Icons.folder_outlined, size: 20),
            onPressed: () =>
                showChatPanel(context, tab: 1, serverId: server.id),
            child: Text(servers.length > 1 ? 'Files: ${server.name}' : 'Files'),
          ),
        ],
        if (admin) ...[
          const Divider(height: 8),
          item(Icons.code, 'Playground', (_) => const PlaygroundScreen()),
          item(
            Icons.admin_panel_settings_outlined,
            'Admin Panel',
            (_) => const AdminScreen(),
          ),
        ],
        const Divider(height: 8),
        item(
          Icons.settings_outlined,
          'Settings',
          (_) => const SettingsScreen(),
        ),
        MenuItemButton(
          style: _menuItem,
          leadingIcon: const Icon(Icons.logout, size: 20),
          onPressed: () async {
            final ok =
                await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const T('Sign out?'),
                    content: const T(
                      "You'll need to sign in again to use OpenAide.",
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const T('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const T('Sign out'),
                      ),
                    ],
                  ),
                ) ??
                false;
            if (ok) await ref.read(sessionProvider.notifier).signOut();
          },
          child: const T('Sign out'),
        ),
      ],
      builder: (context, menu, _) => ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 2, 12, 2),
        leading: Avatar(user: me, radius: 16),
        title: Text(
          name.isEmpty ? 'Account' : name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          Uri.tryParse(session?.serverUrl ?? '')?.host ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Icon(
          menu.isOpen ? Icons.expand_more : Icons.expand_less,
          color: context.nexus.muted,
        ),
        onTap: () => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }
}

/// Closes the chat list when it slid in over the chat; a docked one stays.
void closeDrawer(BuildContext context) {
  final scaffold = Scaffold.maybeOf(context);
  if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
}
