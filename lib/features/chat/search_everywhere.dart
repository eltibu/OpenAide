/// Search everywhere, as the web's search: chats, channel messages and
/// notes, narrowed by kind, by whose they are, and to one folder or channel.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../channels/channels_screen.dart';
import '../notes/notes_api.dart';
import '../notes/notes_screen.dart';
import 'chat_controller.dart';

/// Where a result opens: ('chat', id), ('channel', id), ('note', id), or
/// null for what the app can't open (shared snapshots).
(String, String)? searchTarget(String url) {
  final uri = Uri.parse(url);
  final parts = uri.pathSegments;
  if (parts.length < 2) return null;
  return switch (parts.first) {
    'c' => ('chat', parts[1]),
    'channels' => ('channel', parts[1]),
    'notes' => ('note', parts[1]),
    _ => null,
  };
}

const _kindNames = {
  'all': 'All',
  'chat': 'Chats',
  'message': 'Messages',
  'note': 'Notes',
};

const _sharingNames = {'all': 'Anyone', 'mine': 'Mine', 'shared': 'Shared'};

class SearchEverywhereScreen extends ConsumerStatefulWidget {
  const SearchEverywhereScreen({super.key, this.query = ''});
  final String query;

  @override
  ConsumerState<SearchEverywhereScreen> createState() =>
      _SearchEverywhereScreenState();
}

class _SearchEverywhereScreenState
    extends ConsumerState<SearchEverywhereScreen> {
  late final _query = TextEditingController(text: widget.query);
  String _kind = 'all';
  String _sharing = 'all';
  String _scope = '';
  List<Map> _items = const [];
  List<Map> _scopes = const [];
  List<String> _kinds = const ['chat'];
  bool _more = false;
  bool _loading = false;
  int _page = 1;
  int _generation = 0;
  Object? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _search);
  }

  Future<void> _search({bool more = false}) async {
    final generation = ++_generation;
    final page = more ? _page + 1 : 1;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res =
          await ref
                  .read(clientProvider)
                  .send(
                    'GET',
                    '/api/v1/search',
                    query: {
                      'q': _query.text.trim(),
                      'kind': _kind,
                      'sharing': _sharing,
                      'scope': _scope,
                      'page': '$page',
                    },
                  )
              as Map;
      if (generation != _generation || !mounted) return;
      final items = [...(res['items'] as List? ?? const []).whereType<Map>()];
      setState(() {
        if (more) {
          final seen = {for (final i in _items) i['id']};
          _items = [..._items, ...items.where((i) => !seen.contains(i['id']))];
        } else {
          _items = items;
        }
        _scopes = [...(res['scopes'] as List? ?? const []).whereType<Map>()];
        _kinds = [for (final k in res['kinds'] as List? ?? const []) '$k'];
        _more = res['has_more'] == true;
        _page = page;
      });
    } catch (e) {
      if (generation == _generation && mounted) setState(() => _error = e);
    }
    if (generation == _generation && mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _pickScope() async {
    Widget tile(String id, String name, IconData icon) => ListTile(
      leading: Icon(icon),
      title: Text(name),
      trailing: _scope == id ? const Icon(Icons.check) : null,
      onTap: () => Navigator.pop(context, id),
    );
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            tile('', 'Everywhere', Icons.public),
            for (final (kind, label, icon) in [
              ('folder', 'Folders', Icons.folder_outlined),
              ('channel', 'Channels', Icons.tag),
            ])
              if (_scopes.any((s) => s['kind'] == kind)) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    label,
                    style: TextStyle(color: context.nexus.muted),
                  ),
                ),
                for (final s in _scopes.where((s) => s['kind'] == kind))
                  tile('${s['id']}', '${s['name']}', icon),
              ],
          ],
        ),
      ),
    );
    if (picked != null && picked != _scope) {
      _scope = picked;
      await _search();
    }
  }

  Future<void> _open(Map item) async {
    final target = searchTarget('${item['url'] ?? ''}');
    final navigator = Navigator.of(context);
    switch (target) {
      case ('chat', final id):
        navigator.popUntil((r) => r.isFirst);
        await ref.read(chatControllerProvider.notifier).open(id);
      case ('channel', final id):
        final channel = await ref.read(channelsApiProvider).get(id);
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => ChannelScreen(channel: channel),
          ),
        );
      case ('note', final id):
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => NoteEditorScreen(
              api: NotesApi(ref.read(clientProvider)),
              id: id,
            ),
          ),
        );
      default:
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("This one opens on the web only")),
          );
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final scopeName =
        _scopes.where((s) => s['id'] == _scope).firstOrNull?['name'] ??
        'Everywhere';
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _query,
          autofocus: widget.query.isEmpty,
          textInputAction: TextInputAction.search,
          onChanged: (_) => _changed(),
          onSubmitted: (_) => _search(),
          decoration: const InputDecoration(
            hintText: 'Search chats, messages and notes',
            border: InputBorder.none,
          ),
        ),
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final k in ['all', ..._kinds])
                  if (_kindNames.containsKey(k))
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(_kindNames[k]!),
                        selected: _kind == k,
                        onSelected: (_) {
                          _kind = k;
                          _search();
                        },
                      ),
                    ),
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  tooltip: 'Whose',
                  initialValue: _sharing,
                  onSelected: (v) {
                    _sharing = v;
                    _search();
                  },
                  itemBuilder: (_) => [
                    for (final e in _sharingNames.entries)
                      PopupMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  child: Chip(
                    avatar: const Icon(Icons.person_outline, size: 18),
                    label: Text(_sharingNames[_sharing]!),
                  ),
                ),
                const SizedBox(width: 6),
                ActionChip(
                  tooltip: 'Location',
                  avatar: const Icon(Icons.place_outlined, size: 18),
                  label: Text('$scopeName'),
                  onPressed: _pickScope,
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _error != null
                ? Center(
                    child: Text(
                      'Search is unavailable. Please try again.\n'
                      '$_error',
                    ),
                  )
                : _items.isEmpty && !_loading
                ? Center(
                    child: Text('No results', style: TextStyle(color: muted)),
                  )
                : ListView.builder(
                    itemCount: _items.length + (_more ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == _items.length) {
                        return Padding(
                          padding: const EdgeInsets.all(12),
                          child: Center(
                            child: TextButton(
                              onPressed: _loading
                                  ? null
                                  : () => _search(more: true),
                              child: const Text('Load more'),
                            ),
                          ),
                        );
                      }
                      final item = _items[i];
                      final snippet = '${item['snippet'] ?? ''}'.trim();
                      return ListTile(
                        leading: Icon(switch (item['kind']) {
                          'message' => Icons.tag,
                          'note' => Icons.sticky_note_2_outlined,
                          _ => Icons.chat_bubble_outline,
                        }),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                '${item['title'] ?? ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (item['pinned'] == true)
                              Icon(Icons.push_pin, size: 14, color: muted),
                            if (item['shared'] == true)
                              Icon(
                                Icons.group_outlined,
                                size: 14,
                                color: muted,
                              ),
                          ],
                        ),
                        subtitle: Text(
                          [
                            if ('${item['context'] ?? ''}'.isNotEmpty)
                              '${item['context']}',
                            if (snippet.isNotEmpty) snippet,
                          ].join('\n'),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: muted),
                        ),
                        onTap: () => _open(item),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
