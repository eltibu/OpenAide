/// Open WebUI 0.13.4's folder page: the folder's chats with a search, a
/// status for each chat (statuses the folder sets up, such as Backlog, To
/// do, In progress, Waiting and Done) and a filter by status, and the
/// folder's automations.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme.dart';
import 'chat_controller.dart';

/// A status a folder's chats can have.
class FolderStatus {
  const FolderStatus(this.id, this.name, {this.color = 'gray', this.icon});

  final String id;
  final String name;

  /// One of [folderColors].
  final String color;

  /// An emoji shown instead of the color dot, when set.
  final String? icon;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'glyph': _glyphs.contains(id) ? id : 'todo',
    'color': color,
    'icon': ?icon,
  };
}

const _glyphs = {'backlog', 'todo', 'in_progress', 'waiting', 'done'};

/// The web's tag and status colors.
const folderColors = <String, Color>{
  'gray': Color(0xFF9CA3AF),
  'blue': Color(0xFF3B82F6),
  'violet': Color(0xFF8B5CF6),
  'pink': Color(0xFFEC4899),
  'red': Color(0xFFEF4444),
  'amber': Color(0xFFF59E0B),
  'green': Color(0xFF22C55E),
  'teal': Color(0xFF14B8A6),
};

/// What the web offers when a folder sets up its statuses.
const suggestedFolderStatuses = [
  FolderStatus('backlog', 'Backlog'),
  FolderStatus('todo', 'To do'),
  FolderStatus('in_progress', 'In progress', color: 'amber'),
  FolderStatus('waiting', 'Waiting', color: 'blue'),
  FolderStatus('done', 'Done', color: 'violet'),
];

/// The statuses in a folder's `meta.statuses`, in order, without repeats.
List<FolderStatus> folderStatuses(Map? folder) {
  final list = (folder?['meta'] as Map?)?['statuses'];
  final seen = <String>{'none'};
  return [
    for (final s in (list is List ? list : const []).whereType<Map>())
      if (s['id'] is String &&
          s['name'] is String &&
          (s['id'] as String).isNotEmpty &&
          seen.add(s['id'] as String))
        FolderStatus(
          s['id'] as String,
          s['name'] as String,
          color: folderColors.containsKey(s['color'])
              ? s['color'] as String
              : 'gray',
          icon: s['icon'] is String && (s['icon'] as String).isNotEmpty
              ? s['icon'] as String
              : null,
        ),
  ];
}

/// "3 days", "5 hours", "a few minutes": how long since [since] (seconds).
String timeInStatus(num? since, {DateTime? now}) {
  if (since == null) return '';
  final at = DateTime.fromMillisecondsSinceEpoch((since * 1000).round());
  final d = (now ?? DateTime.now()).difference(at);
  if (d.inDays >= 1) return d.inDays == 1 ? '1 day' : '${d.inDays} days';
  if (d.inHours >= 1) return d.inHours == 1 ? '1 hour' : '${d.inHours} hours';
  if (d.inMinutes >= 2) return '${d.inMinutes} minutes';
  return 'a few minutes';
}

/// A chat on the folder page.
class FolderChat {
  FolderChat(this.json);
  final Map<String, dynamic> json;

  String get id => '${json['id']}';
  String get title => '${json['title'] ?? 'New Chat'}';
  String? get status => json['status'] as String?;
  num? get statusSince => json['status_since'] as num?;
  bool get canEditStatus => json['can_edit_status'] == true;
  bool get waiting => json['pending_approval'] == true;
  bool get active => json['active'] == true;
  bool get automated =>
      (json['meta'] as Map?)?['automation_id'] != null ||
      json['automation_id'] != null;
  String get owner => '${json['owner_name'] ?? ''}';
  bool get readonly => json['readonly'] == true;
}

/// The query for a page of the folder's chats (the web's list view).
Map<String, String> folderChatQuery({
  required int page,
  String search = '',
  String? status,
}) => {
  'workspace': 'true',
  'page': '$page',
  'sort_by': 'updated_at',
  'sort_dir': 'desc',
  if (search.trim().isNotEmpty) 'search': search.trim(),
  'status': ?status,
};

/// The chats part of the folder page, on Open WebUI 0.13.4 and later.
class FolderBoard extends ConsumerStatefulWidget {
  const FolderBoard({
    super.key,
    required this.folderId,
    required this.folder,
    required this.onStatusesChanged,
  });

  final String folderId;
  final VoidCallback onStatusesChanged;

  /// The folder as `/api/v1/folders/{id}` sends it (for its statuses).
  final Map<String, dynamic>? folder;

  @override
  ConsumerState<FolderBoard> createState() => _FolderBoardState();
}

class _FolderBoardState extends ConsumerState<FolderBoard> {
  final _chats = <FolderChat>[];
  int _page = 0;
  bool _more = true;
  bool _loading = false;
  bool _canWrite = false;
  String _search = '';
  String? _status;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FolderBoard old) {
    super.didUpdateWidget(old);
    if (old.folderId != widget.folderId) _reset();
  }

  void _reset() {
    _gen++;
    _chats.clear();
    _page = 0;
    _more = true;
    _loading = false;
    _load();
  }

  Future<void> _load() async {
    if (_loading || !_more) return;
    final gen = _gen;
    setState(() => _loading = true);
    try {
      final res = await ref
          .read(clientProvider)
          .send(
            'GET',
            '/api/v1/folders/${widget.folderId}/shared/chats',
            query: folderChatQuery(
              page: _page + 1,
              search: _search,
              status: _status,
            ),
          );
      if (gen != _gen) return;
      final m = (res as Map).cast<String, dynamic>();
      _page++;
      _chats.addAll([
        for (final c in (m['chats'] as List? ?? const []).whereType<Map>())
          FolderChat(c.cast<String, dynamic>()),
      ]);
      _more = m['has_more'] == true;
      _canWrite = m['folder_permission'] == 'write';
    } catch (_) {
      if (gen == _gen) _more = false;
    }
    if (mounted && gen == _gen) setState(() => _loading = false);
  }

  Future<void> _setStatus(FolderChat c, String? status) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(clientProvider)
          .send(
            'PATCH',
            '/api/v1/folders/${widget.folderId}/chats/${c.id}/status',
            body: {'status': status},
          );
      setState(() {
        c.json['status'] = status;
        c.json['status_since'] = DateTime.now().millisecondsSinceEpoch / 1000;
      });
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _editStatuses(List<FolderStatus> current) async {
    final picked = await showModalBottomSheet<List<FolderStatus>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _StatusesEditor(statuses: current),
    );
    if (picked == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(clientProvider)
          .send(
            'POST',
            '/api/v1/folders/${widget.folderId}/update',
            body: {
              'meta': {
                ...?(widget.folder?['meta'] as Map?)?.cast<String, dynamic>(),
                'statuses': [for (final s in picked) s.toJson()],
              },
            },
          );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
    // The folder page re-reads the folder for its statuses.
    if (mounted) widget.onStatusesChanged();
  }

  Widget _dot(FolderStatus s) => s.icon != null
      ? Text(s.icon!, style: const TextStyle(fontSize: 14))
      : Icon(Icons.circle, size: 12, color: folderColors[s.color]);

  @override
  Widget build(BuildContext context) {
    final statuses = folderStatuses(widget.folder);
    final byId = {for (final s in statuses) s.id: s};
    final muted = context.nexus.muted;
    final controller = ref.read(chatControllerProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: TextField(
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: tr('Search chats'),
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) {
              _search = v;
              _reset();
            },
          ),
        ),
        if (statuses.isNotEmpty || _canWrite)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                if (statuses.isNotEmpty) ...[
                  ChoiceChip(
                    label: T('All'),
                    selected: _status == null,
                    onSelected: (_) {
                      _status = null;
                      _reset();
                    },
                  ),
                  for (final s in [
                    ...statuses,
                    const FolderStatus('none', 'No status'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ChoiceChip(
                        avatar: s.id == 'none' ? null : _dot(s),
                        label: Text(s.name),
                        selected: _status == s.id,
                        onSelected: (_) {
                          _status = s.id;
                          _reset();
                        },
                      ),
                    ),
                ],
                if (_canWrite)
                  TextButton.icon(
                    onPressed: () => _editStatuses(statuses),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: T(
                      statuses.isEmpty ? 'Add statuses' : 'Edit statuses',
                    ),
                  ),
              ],
            ),
          ),
        for (final c in _chats)
          ListTile(
            dense: true,
            leading: c.active
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    c.waiting
                        ? Icons.pending_actions
                        : c.automated
                        ? Icons.schedule
                        : Icons.chat_bubble_outline,
                    size: 18,
                    color: muted,
                  ),
            title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: byId[c.status] == null && !c.readonly
                ? null
                : Text(
                    [
                      if (byId[c.status] != null)
                        '${byId[c.status]!.name} · '
                            '${timeInStatus(c.statusSince)}',
                      if (c.readonly && c.owner.isNotEmpty) c.owner,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing: statuses.isEmpty || !c.canEditStatus
                ? (byId[c.status] == null ? null : _dot(byId[c.status]!))
                : PopupMenuButton<String>(
                    tooltip: tr('Status'),
                    icon: byId[c.status] == null
                        ? Icon(
                            Icons.radio_button_unchecked,
                            size: 16,
                            color: muted,
                          )
                        : _dot(byId[c.status]!),
                    onSelected: (v) => _setStatus(c, v == 'none' ? null : v),
                    itemBuilder: (_) => [
                      for (final s in [
                        ...statuses,
                        const FolderStatus('none', 'No status'),
                      ])
                        CheckedPopupMenuItem(
                          value: s.id,
                          checked: (c.status ?? 'none') == s.id,
                          child: Text(s.name),
                        ),
                    ],
                  ),
            onTap: () => controller.open(c.id),
          ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_more)
          TextButton(onPressed: _load, child: const T('Load more'))
        else if (_chats.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: T(
              _search.isEmpty && _status == null
                  ? 'No chats in this folder yet.'
                  : 'No chats match.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted),
            ),
          ),
      ],
    );
  }
}

/// Sets up a folder's statuses: suggestions to add, and each one's name
/// and color.
class _StatusesEditor extends StatefulWidget {
  const _StatusesEditor({required this.statuses});
  final List<FolderStatus> statuses;

  @override
  State<_StatusesEditor> createState() => _StatusesEditorState();
}

class _StatusesEditorState extends State<_StatusesEditor> {
  late final List<FolderStatus> _list = [...widget.statuses];

  String _newId(String name) {
    final base = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    var id = base.isEmpty ? 'status' : base;
    var n = 2;
    while (id == 'none' || _list.any((s) => s.id == id)) {
      id = '${base.isEmpty ? 'status' : base}_${n++}';
    }
    return id.length > 64 ? id.substring(0, 64) : id;
  }

  Future<void> _add() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const T('New status'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('Name')),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, ctrl.text),
            child: const T('Add'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    setState(() => _list.add(FolderStatus(_newId(name), name.trim())));
  }

  @override
  Widget build(BuildContext context) {
    final unused = [
      for (final s in suggestedFolderStatuses)
        if (!_list.any((x) => x.id == s.id)) s,
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: T(
                    'Edit statuses',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _list),
                  child: const T('Save'),
                ),
              ],
            ),
            Flexible(
              child: ReorderableListView(
                shrinkWrap: true,
                buildDefaultDragHandles: true,
                onReorderItem: (from, to) => setState(() {
                  final s = _list.removeAt(from);
                  _list.insert(to, s);
                }),
                children: [
                  for (final (i, s) in _list.indexed)
                    ListTile(
                      key: ValueKey(s.id),
                      contentPadding: EdgeInsets.zero,
                      leading: PopupMenuButton<String>(
                        tooltip: tr('Color'),
                        icon: Icon(Icons.circle, color: folderColors[s.color]),
                        onSelected: (c) => setState(
                          () => _list[i] = FolderStatus(
                            s.id,
                            s.name,
                            color: c,
                            icon: s.icon,
                          ),
                        ),
                        itemBuilder: (_) => [
                          for (final e in folderColors.entries)
                            PopupMenuItem(
                              value: e.key,
                              child: Row(
                                children: [
                                  Icon(Icons.circle, color: e.value),
                                  const SizedBox(width: 8),
                                  Text(e.key),
                                ],
                              ),
                            ),
                        ],
                      ),
                      title: Text(s.name),
                      trailing: IconButton(
                        tooltip: tr('Remove'),
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _list.removeAt(i)),
                      ),
                    ),
                ],
              ),
            ),
            if (unused.isNotEmpty)
              Wrap(
                spacing: 6,
                children: [
                  for (final s in unused)
                    ActionChip(
                      avatar: Icon(
                        Icons.add,
                        size: 16,
                        color: folderColors[s.color],
                      ),
                      label: Text(s.name),
                      onPressed: () => setState(() => _list.add(s)),
                    ),
                ],
              ),
            TextButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const T('Add a status'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The folder's automations (0.13.4), with their state and last run.
final folderAutomationsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, id) async {
      final res = await ref
          .watch(clientProvider)
          .send('GET', '/api/v1/folders/$id/automations');
      return [
        for (final a in (res as List? ?? const []).whereType<Map>())
          a.cast<String, dynamic>(),
      ];
    });

/// One line for an automation: on or paused, and how its last run went.
String folderAutomationSummary(Map a) {
  final run = a['last_run'] as Map?;
  return [
    if (a['is_active'] == false) 'Paused' else 'On',
    if (run != null) 'last run ${run['status'] ?? ''}'.trim(),
    if ('${a['user_name'] ?? ''}'.isNotEmpty) 'by ${a['user_name']}',
  ].join(' · ');
}
