/// The Inbox (Open WebUI 0.13): comments on your things, replies to your
/// comments, mentions in comments and channels, replies in channels, failed
/// automation runs and coming calendar events, with an unread count. Shown
/// when the server has it on (`enable_notifications`).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme.dart';
import '../../core/widgets/empty_state.dart';
import '../automations/automations_api.dart';
import '../automations/automations_screen.dart';
import '../calendar/calendar_screen.dart';
import '../channels/channels_api.dart' show showMentions;
import '../channels/channels_screen.dart'
    show ChannelScreen, channelsApiProvider;
import '../chat/chat_controller.dart'
    show chatControllerProvider, serverConfigProvider;
import '../comments/comments.dart' show showComments;
import '../notes/notes_api.dart';
import '../notes/notes_screen.dart' show NoteEditorScreen;

/// Whether the server has the inbox on.
bool inboxOn(WidgetRef ref) =>
    ((ref.watch(serverConfigProvider).value?['features']
        as Map?)?['enable_notifications']) ==
    true;

class InboxItem {
  InboxItem(this.raw);
  final Map<String, dynamic> raw;

  String get id => '${raw['id']}';
  String get event => '${raw['event_type'] ?? ''}';
  String get actor => '${(raw['actor'] as Map?)?['name'] ?? ''}';
  String? get resourceType => raw['resource_type'] as String?;
  String? get resourceId => raw['resource_id'] as String?;
  String? get objectType => raw['object_type'] as String?;
  String? get objectId => raw['object_id'] as String?;
  String get title => '${raw['title'] ?? ''}';
  String get preview => '${raw['preview'] ?? ''}';
  Map get data => (raw['data'] as Map?) ?? const {};
  bool get read => raw['read_at'] != null;
  bool get fresh => raw['is_new'] == true;

  /// Epoch nanoseconds, sent as text.
  DateTime get created => DateTime.fromMicrosecondsSinceEpoch(
    (int.tryParse('${raw['created_at']}') ?? 0) ~/ 1000,
  );

  /// The line the web shows for it.
  String get label {
    final who = actor.isEmpty ? tr('Unknown User') : actor;
    final text = switch (event) {
      'comment.created' => tr('{{name}} commented'),
      'comment.replied' || 'channel.replied' => tr('{{name}} replied'),
      'comment.mentioned' ||
      'channel.mentioned' => tr('{{name}} mentioned you'),
      'calendar.alert' => tr('Upcoming event'),
      'automation.run_failed' => tr('Automation failed'),
      'system.announcement' => tr('Announcement'),
      _ => tr('Notification'),
    };
    return text.replaceAll('{{name}}', who);
  }

  IconData get icon => switch (event.split('.').first) {
    'comment' => Icons.mode_comment_outlined,
    'channel' => Icons.tag,
    'calendar' => Icons.event_outlined,
    'automation' => Icons.error_outline,
    _ => Icons.notifications_none,
  };
}

class InboxApi {
  InboxApi(this.client);
  final OpenWebUiClient client;
  static const _base = '/api/v1/notifications/inbox';

  ({List<InboxItem> items, String? next, int? count}) _page(Object? res) {
    final m = (res as Map?) ?? const {};
    return (
      items: [
        for (final i in m['items'] as List? ?? const [])
          if (i is Map) InboxItem(i.cast<String, dynamic>()),
      ],
      next: m['next_cursor'] as String?,
      count: (m['count'] as num?)?.toInt(),
    );
  }

  Future<int> count() async =>
      (((await client.send('GET', '$_base/count')) as Map?)?['count'] as num?)
          ?.toInt() ??
      0;

  /// Opening the inbox marks what's there as seen and returns the first
  /// page, with what was new flagged.
  Future<({List<InboxItem> items, String? next, int? count})> open() async =>
      _page(await client.send('POST', '$_base/open'));

  Future<({List<InboxItem> items, String? next, int? count})> page(
    String? cursor,
  ) async => _page(await client.send('GET', _base, query: {'cursor': ?cursor}));

  /// Marks one as read.
  Future<void> read(String id) =>
      client.send('PATCH', '$_base/${Uri.encodeComponent(id)}');
}

final inboxApiProvider = Provider((ref) => InboxApi(ref.watch(clientProvider)));

/// Unread notifications; follows the server's live nudges.
final inboxCountProvider = StreamProvider.autoDispose<int>((ref) async* {
  final api = ref.watch(inboxApiProvider);
  final socket = ref.watch(chatSocketProvider);
  final changes = StreamController<void>();
  final sub = socket.inboxChanged.listen((_) => changes.add(null));
  ref.onDispose(() {
    sub.cancel();
    changes.close();
  });
  Future<int?> fetch() async {
    try {
      return await api.count();
    } catch (_) {
      return null;
    }
  }

  final first = await fetch();
  if (first != null) yield first;
  await for (final _ in changes.stream) {
    final n = await fetch();
    if (n != null) yield n;
  }
});

/// The drawer row: Inbox, with the unread count.
class InboxRow extends ConsumerWidget {
  const InboxRow({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(inboxCountProvider).value ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          height: 40,
          child: Row(
            children: [
              const SizedBox(width: 12),
              const Icon(Icons.inbox_outlined, size: 20),
              const SizedBox(width: 14),
              const Expanded(child: T('Inbox', style: TextStyle(fontSize: 15))),
              if (count > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Badge(
                    label: Text(count > 99 ? '99+' : '$count'),
                    backgroundColor: NexusColors.accent,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  List<InboxItem> _items = const [];
  String? _next;
  bool _loading = true;
  bool _more = false;
  Object? _error;
  StreamSubscription? _changes;
  Timer? _debounce;

  InboxApi get _api => ref.read(inboxApiProvider);

  @override
  void initState() {
    super.initState();
    _load(open: true);
    _changes = ref.read(chatSocketProvider).inboxChanged.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), _load);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _changes?.cancel();
    super.dispose();
  }

  Future<void> _load({bool open = false}) async {
    try {
      final page = open ? await _api.open() : await _api.page(null);
      if (!mounted) return;
      // Keep the "new" marks from opening while live updates come in.
      final fresh = {
        for (final i in _items)
          if (i.fresh) i.id,
      };
      setState(() {
        _items = [
          for (final i in page.items)
            fresh.contains(i.id) ? (InboxItem({...i.raw, 'is_new': true})) : i,
        ];
        _next = page.next;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_next == null || _more) return;
    setState(() => _more = true);
    try {
      final page = await _api.page(_next);
      if (mounted) {
        setState(() {
          _items = [..._items, ...page.items];
          _next = page.next;
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _more = false);
  }

  Future<void> _open(InboxItem item) async {
    if (!item.read) {
      unawaited(_api.read(item.id).catchError((_) {}));
      setState(() {
        _items = [
          for (final i in _items)
            i.id == item.id
                ? InboxItem({...i.raw, 'read_at': '${DateTime.now()}'})
                : i,
        ];
      });
    }
    final navigator = Navigator.of(context);
    final type = item.resourceType;
    final id = item.resourceId;
    if (type == null || id == null) return;
    try {
      if (item.objectType == 'comment' && type == 'chat') {
        navigator.popUntil((r) => r.isFirst);
        await ref.read(chatControllerProvider.notifier).open(id);
        final root = navigator.context;
        if (root.mounted) {
          await showComments(
            // The chat's own screen, still there after this one closed.
            // ignore: use_build_context_synchronously
            root,
            type: 'chat',
            id: id,
            title: item.title,
          );
        }
      } else if (item.objectType == 'comment' && type == 'note') {
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => NoteEditorScreen(
              api: NotesApi(ref.read(clientProvider)),
              id: id,
            ),
          ),
        );
      } else if (item.objectType == 'comment') {
        if (mounted) {
          await showComments(context, type: type, id: id, title: item.title);
        }
      } else if (type == 'channel') {
        final channel = await ref.read(channelsApiProvider).get(id);
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => ChannelScreen(channel: channel),
          ),
        );
      } else if (type == 'automation') {
        await navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => AutomationDetail(
              api: AutomationsApi(ref.read(clientProvider)),
              id: id,
            ),
          ),
        );
      } else if (type == 'calendar') {
        await navigator.push(
          MaterialPageRoute<void>(builder: (_) => const CalendarScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is ApiException ? e.message : '$e')),
        );
      }
    }
  }

  String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return tr('Now');
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    return MaterialLocalizations.of(context).formatShortDate(t);
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(title: const T('Inbox')),
      body: RefreshIndicator(
        onRefresh: () => _load(open: true),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _error is ApiException
                          ? (_error as ApiException).message
                          : '$_error',
                    ),
                  ),
                ],
              )
            : NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.metrics.extentAfter < 300) _loadMore();
                  return false;
                },
                child: ListView(
                  children: [
                    if (_items.isEmpty)
                      const EmptyState(
                        icon: Icons.inbox_outlined,
                        title: 'No notifications found.',
                      ),
                    for (final i in _items)
                      ListTile(
                        leading: Badge(
                          isLabelVisible: !i.read,
                          smallSize: 8,
                          backgroundColor: NexusColors.accent,
                          child: Icon(i.icon),
                        ),
                        title: Text(
                          i.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: i.read
                              ? null
                              : const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (i.title.isNotEmpty)
                              Text(
                                i.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            if (i.preview.isNotEmpty)
                              Text(
                                showMentions(i.preview).replaceAll('**', ''),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: muted),
                              ),
                          ],
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              _when(i.created),
                              style: TextStyle(color: muted, fontSize: 12),
                            ),
                            if (i.fresh)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: T(
                                  'New',
                                  style: TextStyle(
                                    color: NexusColors.accent,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        onTap: () => _open(i),
                      ),
                    if (_more)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
