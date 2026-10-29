/// Folders other people shared with you, as the web's "Shared with you" in
/// the sidebar: their chats, newest first, read only unless you were given
/// write access.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import 'chat_controller.dart';
import '../../core/i18n/app_strings.dart';

class SharedFolder {
  const SharedFolder({
    required this.id,
    required this.name,
    required this.owner,
    required this.writable,
    this.parentId,
  });

  factory SharedFolder.fromJson(Map j) => SharedFolder(
    id: '${j['id']}',
    name: '${j['name'] ?? ''}',
    owner: '${j['owner_name'] ?? ''}',
    writable: j['permission'] == 'write',
    parentId: j['parent_id'] as String?,
  );

  final String id;
  final String name;
  final String owner;
  final bool writable;
  final String? parentId;
}

class SharedChat {
  const SharedChat(this.id, this.title, this.owner, this.readOnly);

  factory SharedChat.fromJson(Map j) => SharedChat(
    '${j['id']}',
    '${j['title'] ?? 'Chat'}',
    '${j['owner_name'] ?? ''}',
    j['readonly'] == true,
  );

  final String id;
  final String title;
  final String owner;
  final bool readOnly;
}

/// Folders shared with you; the ones you own are left out, since they're
/// in your own list.
final sharedFoldersProvider = FutureProvider<List<SharedFolder>>((ref) async {
  try {
    final res = await ref
        .watch(clientProvider)
        .send('GET', '/api/v1/folders/shared');
    final me = ref.watch(sessionProvider).value?.user?['id'];
    return [
      for (final f in (res as List? ?? const []).whereType<Map>())
        if (me == null || f['user_id'] != me) SharedFolder.fromJson(f),
    ];
  } catch (_) {
    return const [];
  }
});

/// One page of ten of a shared folder's chats, and whether more follow.
Future<(List<SharedChat>, bool)> sharedFolderChats(
  WidgetRef ref,
  String folderId,
  int page,
) async {
  final res =
      await ref
              .read(clientProvider)
              .send(
                'GET',
                '/api/v1/folders/$folderId/shared/chats',
                query: {'page': '$page'},
              )
          as Map;
  final chats = [
    for (final c in (res['chats'] as List? ?? const []).whereType<Map>())
      SharedChat.fromJson(c),
  ];
  return (chats, res['has_more'] == true);
}

class SharedFolderScreen extends ConsumerStatefulWidget {
  const SharedFolderScreen({super.key, required this.folder});
  final SharedFolder folder;

  @override
  ConsumerState<SharedFolderScreen> createState() => _SharedFolderScreenState();
}

class _SharedFolderScreenState extends ConsumerState<SharedFolderScreen> {
  final _chats = <SharedChat>[];
  int _page = 0;
  bool _more = true;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading || !_more) return;
    setState(() => _loading = true);
    try {
      final (list, more) = await sharedFolderChats(
        ref,
        widget.folder.id,
        _page + 1,
      );
      _page++;
      _chats.addAll(list);
      _more = more;
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.folder;
    final muted = context.nexus.muted;
    final subfolders = (ref.watch(sharedFoldersProvider).value ?? const [])
        .where((s) => s.parentId == f.id);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(f.name),
            Text(
              '${f.owner.isEmpty ? 'Shared' : 'From ${f.owner}'}'
              '${f.writable ? '' : ' · Read only'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      body: ListView(
        children: [
          for (final s in subfolders)
            ListTile(
              leading: const Icon(Icons.folder_shared_outlined),
              title: Text(s.name),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => SharedFolderScreen(folder: s),
                ),
              ),
            ),
          for (final c in _chats)
            ListTile(
              leading: Icon(
                c.readOnly ? Icons.visibility_outlined : Icons.chat_outlined,
                color: muted,
              ),
              title: Text(
                c.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: c.owner.isEmpty ? null : Text(c.owner),
              onTap: () {
                ref.read(chatControllerProvider.notifier).open(c.id);
                Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          if (_error != null)
            ListTile(
              title: Text("Couldn't load the chats: $_error"),
              trailing: TextButton(onPressed: _load, child: const T('Retry')),
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_more && _error == null)
            TextButton(onPressed: _load, child: const T('Load more'))
          else if (_chats.isEmpty && subfolders.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: T('No chats here yet.', style: TextStyle(color: muted)),
            ),
        ],
      ),
    );
  }
}
