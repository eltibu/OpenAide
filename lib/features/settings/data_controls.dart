/// Settings > Data controls, as on the web: import and export every chat,
/// the chats you've shared, archiving or deleting them all, and the files
/// you've uploaded.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import 'settings_screen.dart';

/// Chats from an export file: a JSON list (the web's export), one chat, or
/// one chat per line.
List<Map<String, dynamic>> parseChatExport(String text) {
  final t = text.trim();
  if (t.isEmpty) return const [];
  Object? data;
  try {
    data = jsonDecode(t);
  } on FormatException {
    data = [
      for (final line in const LineSplitter().convert(t))
        if (line.trim().isNotEmpty) jsonDecode(line),
    ];
  }
  final list = data is List ? data : [data];
  return [
    for (final c in list)
      if (c is Map) c.cast<String, dynamic>(),
  ];
}

/// What the server's import takes for each chat, as the web sends it.
Map<String, dynamic> importEntry(Map<String, dynamic> c) => c['chat'] is Map
    ? {
        'chat': c['chat'],
        'meta': c['meta'] ?? {},
        'pinned': c['pinned'] ?? false,
        'archived': c['archived'] ?? false,
        'folder_id': c['folder_id'],
        'created_at': c['created_at'],
        'updated_at': c['updated_at'],
      }
    // An older export: the chat itself.
    : {
        'chat': c,
        'meta': {},
        'pinned': false,
        'folder_id': null,
        'created_at': c['created_at'],
        'updated_at': c['updated_at'],
      };

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

class DataControls extends ConsumerWidget {
  const DataControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    final error = Theme.of(context).colorScheme.error;
    final muted = context.nexus.muted;
    void open(Widget page) =>
        Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));

    Future<void> import() async {
      final picked = await FilePicker.pickFiles();
      if (picked.isEmpty || !context.mounted) return;
      try {
        final chats = parseChatExport(
          utf8.decode(await picked.first.readAsBytes(), allowMalformed: true),
        );
        if (chats.isEmpty) throw const FormatException('No chats in that file');
        final res = await client.send(
          'POST',
          '/api/v1/chats/import',
          body: {'chats': chats.map(importEntry).toList()},
        );
        refreshChatLists(ref.invalidate);
        if (context.mounted) {
          _say(
            context,
            'Imported ${res is List ? res.length : chats.length} chats',
          );
        }
      } catch (e) {
        if (context.mounted) _say(context, "Couldn't import: $e");
      }
    }

    Future<void> export() async {
      try {
        final text = utf8.decode(
          await client.getBytes('/api/v1/chats/all'),
          allowMalformed: true,
        );
        final chats = parseChatExport(text);
        final day = DateTime.now().toIso8601String().substring(0, 10);
        final saved = await FilePicker.saveFile(
          fileName: 'chat-export-$day.json',
          bytes: Uint8List.fromList(utf8.encode(jsonEncode(chats))),
          mimeType: 'application/json',
        );
        if (saved != null && context.mounted) {
          _say(context, 'Exported ${chats.length} chats');
        }
      } catch (e) {
        if (context.mounted) _say(context, "Couldn't export: $e");
      }
    }

    Future<void> act(
      String title,
      String body,
      String action,
      Future<void> Function() run,
      String done,
    ) async {
      final ok = await showDialog<bool>(
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
              child: Text(action),
            ),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await run();
        refreshChatLists(ref.invalidate);
        if (context.mounted) _say(context, done);
      } catch (e) {
        if (context.mounted) _say(context, '$e');
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Data controls')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: const Text('Import chats'),
            subtitle: const Text('From a chat export file (JSON)'),
            onTap: import,
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Export all chats'),
            subtitle: const Text('Every chat, as one JSON file'),
            onTap: export,
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Shared chats'),
            subtitle: const Text('Links you\'ve made, copy or remove them'),
            onTap: () => open(const SharedChatsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('Archived chats'),
            onTap: () => open(const ArchivedChatsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('Archive all chats'),
            onTap: () => act(
              'Archive all chats?',
              'They move to Archived chats, where you can bring them back.',
              'Archive all',
              ref.read(settingsApiProvider).archiveAll,
              'All chats archived',
            ),
          ),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: error),
            title: Text('Delete all chats', style: TextStyle(color: error)),
            subtitle: Text(
              'Removes every chat from the server',
              style: TextStyle(color: muted),
            ),
            onTap: () => act(
              'Delete all chats?',
              'Every chat is deleted from the server. This can\'t be undone.',
              'Delete all',
              ref.read(settingsApiProvider).deleteAllChats,
              'All chats deleted',
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('Your files'),
            subtitle: const Text('Everything you\'ve uploaded to the server'),
            onTap: () => open(const YourFilesScreen()),
          ),
        ],
      ),
    );
  }
}

// ---- Shared chats ----

final sharedChatsProvider = FutureProvider.autoDispose<List<Map>>((ref) async {
  final res = await ref
      .watch(clientProvider)
      .send('GET', '/api/v1/chats/shared');
  return [
    for (final c in res as List? ?? const [])
      if (c is Map) c,
  ];
});

class SharedChatsScreen extends ConsumerWidget {
  const SharedChatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(sharedChatsProvider);
    final client = ref.watch(clientProvider);
    final muted = context.nexus.muted;
    Future<void> unshare(String id) async {
      try {
        await client.send('DELETE', '/api/v1/chats/$id/share');
      } catch (e) {
        if (context.mounted) _say(context, '$e');
      }
      ref.invalidate(sharedChatsProvider);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Shared chats'),
        actions: [
          if (list.value?.isNotEmpty ?? false)
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Stop sharing all chats?'),
                    content: const Text(
                      'Every shared link stops working. The chats stay.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Stop all'),
                      ),
                    ],
                  ),
                );
                if (ok != true) return;
                for (final c in list.value ?? const <Map>[]) {
                  try {
                    await client.send(
                      'DELETE',
                      '/api/v1/chats/${c['chat_id'] ?? c['id']}/share',
                    );
                  } catch (_) {}
                }
                ref.invalidate(sharedChatsProvider);
              },
              child: const Text('Stop all'),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(sharedChatsProvider.future),
        child: list.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load shared chats.\n$e'),
              ),
            ],
          ),
          data: (chats) => chats.isEmpty
              ? ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'You haven\'t shared any chats. Share one from its '
                        'menu in the chat list.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: muted),
                      ),
                    ),
                  ],
                )
              : ListView(
                  children: [
                    for (final c in chats)
                      ListTile(
                        title: Text(
                          '${c['title'] ?? 'Chat'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${client.baseUrl}/s/${c['share_id']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: muted),
                        ),
                        onTap: () {
                          ref
                              .read(chatControllerProvider.notifier)
                              .open('${c['chat_id'] ?? c['id']}');
                          Navigator.popUntil(context, (r) => r.isFirst);
                        },
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Copy link',
                              icon: const Icon(Icons.copy, size: 20),
                              onPressed: () async {
                                await Clipboard.setData(
                                  ClipboardData(
                                    text:
                                        '${client.baseUrl}/s/${c['share_id']}',
                                  ),
                                );
                                if (context.mounted) {
                                  _say(context, 'Link copied');
                                }
                              },
                            ),
                            IconButton(
                              tooltip: 'Stop sharing',
                              icon: const Icon(Icons.link_off, size: 20),
                              onPressed: () =>
                                  unshare('${c['chat_id'] ?? c['id']}'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

// ---- Your files ----

String fileSize(num? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class YourFilesScreen extends ConsumerStatefulWidget {
  const YourFilesScreen({super.key});

  @override
  ConsumerState<YourFilesScreen> createState() => _YourFilesScreenState();
}

class _YourFilesScreenState extends ConsumerState<YourFilesScreen> {
  final _files = <Map>[];
  final _search = TextEditingController();
  int _page = 0;
  int _total = 0;
  bool _loading = false;
  bool _done = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _more();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _files.clear();
      _page = 0;
      _done = false;
      _error = null;
    });
    await _more();
  }

  Future<void> _more() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    final client = ref.read(clientProvider);
    final query = _search.text.trim();
    try {
      if (query.isEmpty) {
        final res = await client.send(
          'GET',
          '/api/v1/files/',
          query: {'page': '${_page + 1}', 'content': 'false'},
        );
        final items = (res as Map)['items'] as List? ?? const [];
        _total = (res['total'] as num?)?.toInt() ?? 0;
        _files.addAll(items.whereType<Map>());
        _page++;
        _done = items.isEmpty || _files.length >= _total;
      } else {
        final res = await client.send(
          'GET',
          '/api/v1/files/user/search',
          query: {'filename': '*$query*', 'limit': '200'},
        );
        _files.addAll((res as List? ?? const []).whereType<Map>());
        _total = _files.length;
        _done = true;
      }
    } catch (e) {
      _error = e;
      _done = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _delete(Map f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this file?'),
        content: Text(
          '${f['filename']} is removed from the server, and from any '
          'knowledge it was in.',
        ),
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
    );
    if (ok != true) return;
    try {
      await ref.read(clientProvider).send('DELETE', '/api/v1/files/${f['id']}');
      setState(() {
        _files.remove(f);
        _total = _total > 0 ? _total - 1 : 0;
      });
    } catch (e) {
      if (mounted) _say(context, "Couldn't delete: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: Text(_total > 0 ? 'Your files ($_total)' : 'Your files'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search by name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _reload(),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.metrics.extentAfter < 400) _more();
                  return false;
                },
                child: ListView(
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('Couldn\'t load your files.\n$_error'),
                      ),
                    if (_files.isEmpty && !_loading && _error == null)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'No files.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: muted),
                        ),
                      ),
                    for (final f in _files)
                      ListTile(
                        leading: Icon(_icon(f)),
                        title: Text(
                          '${f['filename']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            fileSize((f['meta'] as Map?)?['size'] as num?),
                            _date(f['created_at']),
                          ].where((s) => s.isNotEmpty).join(' · '),
                          style: TextStyle(color: muted),
                        ),
                        trailing: IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(f),
                        ),
                      ),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _icon(Map f) {
    final type = '${(f['meta'] as Map?)?['content_type'] ?? ''}';
    if (type.startsWith('image/')) return Icons.image_outlined;
    if (type.startsWith('audio/')) return Icons.audio_file_outlined;
    if (type.startsWith('video/')) return Icons.video_file_outlined;
    if (type.contains('pdf')) return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }

  String _date(Object? seconds) {
    if (seconds is! num) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
}
