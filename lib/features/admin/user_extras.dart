/// Admin > Users, for one person: their chats (when the server lets admins
/// read them) and a preview of what they can reach, as the web's Chats and
/// Preview Access buttons.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../../core/theme.dart';
import '../../core/widgets/search_field.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// A person's chats, newest first, with search, reading and deleting.
class UserChatsScreen extends ConsumerStatefulWidget {
  const UserChatsScreen({super.key, required this.userId, required this.name});
  final String userId, name;

  @override
  ConsumerState<UserChatsScreen> createState() => _UserChatsState();
}

class _UserChatsState extends ConsumerState<UserChatsScreen> {
  List<Map<String, dynamic>> _chats = [];
  Object? _error;
  bool _loading = true;
  bool _all = false;
  int _page = 1;
  String _query = '';
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    final ask = ++_asked;
    setState(() => _loading = true);
    if (!more) _page = 1;
    try {
      final res = await ref
          .read(clientProvider)
          .send(
            'GET',
            '/api/v1/chats/list/user/${Uri.encodeComponent(widget.userId)}',
            query: {
              'page': '$_page',
              'order_by': 'updated_at',
              'direction': 'desc',
              if (_query.isNotEmpty) 'query': _query,
            },
          );
      if (ask != _asked) return;
      final items = [
        for (final c in res as List? ?? const [])
          if (c is Map) c.cast<String, dynamic>(),
      ];
      final have = {for (final c in _chats) c['id']};
      _chats = more
          ? [
              ..._chats,
              for (final c in items)
                if (!have.contains(c['id'])) c,
            ]
          : items;
      _all = items.isEmpty;
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _delete(Map<String, dynamic> c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete "${c['title']}"?'),
        content: Text('It is deleted for ${widget.name} too.'),
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
    try {
      await ref.read(clientProvider).send('DELETE', '/api/v1/chats/${c['id']}');
      setState(() => _chats.remove(c));
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(title: Text("${widget.name}'s Chats")),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SearchField(
              hint: 'Search chats',
              onChanged: (v) {
                _query = v.trim();
                _load();
              },
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _error != null && _chats.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        "Couldn't load the chats.\n$_error\n\nThe server "
                        'may not let admins read chats.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : _chats.isEmpty && !_loading
                ? Center(
                    child: Text(
                      'No chats found for this user.',
                      style: TextStyle(color: muted),
                    ),
                  )
                : NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (!_loading && !_all && n.metrics.extentAfter < 200) {
                        _page++;
                        _load(more: true);
                      }
                      return false;
                    },
                    child: ListView(
                      children: [
                        for (final c in _chats)
                          ListTile(
                            title: Text('${c['title'] ?? 'Chat'}'),
                            subtitle: Text(
                              _date(c['updated_at']),
                              style: TextStyle(color: muted),
                            ),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => _ChatReader(
                                  id: '${c['id']}',
                                  title: '${c['title'] ?? 'Chat'}',
                                ),
                              ),
                            ),
                            trailing: IconButton(
                              tooltip: 'Delete',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(c),
                            ),
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

String _date(Object? seconds) {
  if (seconds is! num) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// Someone else's chat, to read only.
class _ChatReader extends ConsumerStatefulWidget {
  const _ChatReader({required this.id, required this.title});
  final String id, title;

  @override
  ConsumerState<_ChatReader> createState() => _ChatReaderState();
}

class _ChatReaderState extends ConsumerState<_ChatReader> {
  Chat? _chat;
  Object? _error;

  @override
  void initState() {
    super.initState();
    ref
        .read(clientProvider)
        .chat(widget.id)
        .then((c) {
          if (mounted) setState(() => _chat = c);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e);
        });
  }

  @override
  Widget build(BuildContext context) {
    final chat = _chat;
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _error != null
          ? Center(child: Text('$_error'))
          : chat == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final m in chat.thread)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.role == 'user' ? 'User' : (m.model ?? 'Assistant'),
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        SelectableText(m.content),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

/// What a person can reach: their groups, and the models, knowledge and
/// tools open to them.
class UserPreviewScreen extends ConsumerWidget {
  const UserPreviewScreen({
    super.key,
    required this.userId,
    required this.name,
  });
  final String userId, name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(title: Text('User Preview: $name')),
      body: FutureBuilder(
        future: ref
            .read(clientProvider)
            .send(
              'GET',
              '/api/v1/users/${Uri.encodeComponent(userId)}/preview',
            ),
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          final p = snap.data;
          if (p is! Map) {
            return const Center(child: CircularProgressIndicator());
          }
          Widget part(String title, String key, String none) {
            final part = (p[key] as Map?) ?? const {};
            final items = [
              for (final i in part['items'] as List? ?? const [])
                if (i is Map) '${i['name'] ?? i['id']}',
            ];
            final total = part['total'] as int? ?? items.length;
            return ListTile(
              title: Text(title),
              subtitle: Text(
                items.isEmpty
                    ? none
                    : [
                        items.join(', '),
                        if (total > items.length)
                          '${items.length} of $total accessible',
                      ].join(' · '),
                style: TextStyle(color: muted),
              ),
            );
          }

          final groups = [
            for (final g in p['groups'] as List? ?? const [])
              if (g is Map) '${g['name']}',
          ];
          return ListView(
            children: [
              ListTile(
                title: const Text('Groups'),
                subtitle: Text(
                  groups.isEmpty ? 'In no groups' : groups.join(', '),
                  style: TextStyle(color: muted),
                ),
              ),
              part('Models', 'models', 'No models accessible'),
              part('Knowledge', 'knowledge', 'No knowledge bases accessible'),
              part('Tools', 'tools', 'No tools accessible'),
            ],
          );
        },
      ),
    );
  }
}
