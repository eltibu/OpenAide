/// Managing a channel, as on the web: its pinned messages, who is in it,
/// its webhooks, its name, and making new channels and direct messages.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../admin/apps_screen.dart' show AppsApi, ServerApp;
import '../chat/chat_controller.dart' show serverConfigProvider;
import 'channels_api.dart';
import '../../core/i18n/app_strings.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(text))));

/// Whether the signed-in person can rename, delete or change who is in [c].
bool canManage(WidgetRef ref, Channel c) {
  final user = ref.read(sessionProvider).value?.user;
  return c.raw['is_manager'] == true ||
      user?['role'] == 'admin' ||
      (c.ownerId != null && c.ownerId == user?['id']);
}

/// A sheet of the channel's pinned messages; returns the one tapped.
Future<ChannelMessage?> showPinned(
  BuildContext context,
  ChannelsApi api,
  String channelId,
) => showModalBottomSheet<ChannelMessage>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (sheet) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    builder: (_, scroll) => FutureBuilder<List<ChannelMessage>>(
      future: api.pinned(channelId),
      builder: (context, snap) {
        final muted = context.nexus.muted;
        if (snap.hasError) {
          return Center(child: Text('Couldn\'t load pins.\n${snap.error}'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final list = snap.data!;
        return ListView(
          controller: scroll,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: T(
                'Pinned messages',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: T(
                  'Nothing pinned yet. Long-press a message to pin it.',
                  style: TextStyle(color: muted),
                ),
              ),
            for (final m in list)
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: Text(
                  showMentions(m.content).replaceAll('**', ''),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(m.author),
                onTap: () => Navigator.pop(sheet, m),
              ),
          ],
        );
      },
    ),
  ),
);

/// Asks for a name and description; null when cancelled.
Future<({String name, String description})?> askChannelDetails(
  BuildContext context, {
  String title = 'New channel',
  String name = '',
  String description = '',
  String action = 'Create',
}) async {
  final n = TextEditingController(text: name);
  final d = TextEditingController(text: description);
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: n,
            autofocus: true,
            decoration: InputDecoration(labelText: tr('Name')),
          ),
          TextField(
            controller: d,
            decoration: InputDecoration(labelText: tr('Description')),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const T('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(action),
        ),
      ],
    ),
  );
  final result = (name: n.text.trim(), description: d.text.trim());
  // Not disposed: the dialog's text field still builds while it closes.
  return ok == true && result.name.isNotEmpty ? result : null;
}

/// Picks one person by name or email; null when cancelled.
Future<ChannelMember?> pickPerson(
  BuildContext context,
  ChannelsApi api, {
  String title = 'Add someone',
  Set<String> skip = const {},
}) => showModalBottomSheet<ChannelMember>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _PersonPicker(api: api, title: title, skip: skip),
);

class _PersonPicker extends StatefulWidget {
  const _PersonPicker({
    required this.api,
    required this.title,
    required this.skip,
  });
  final ChannelsApi api;
  final String title;
  final Set<String> skip;

  @override
  State<_PersonPicker> createState() => _PersonPickerState();
}

class _PersonPickerState extends State<_PersonPicker> {
  List<ChannelMember> _found = const [];
  Object? _error;
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  Future<void> _search(String q) async {
    final ask = ++_asked;
    try {
      final found = await widget.api.searchUsers(q);
      if (mounted && ask == _asked) {
        setState(() {
          _found = [
            for (final u in found)
              if (!widget.skip.contains(u.id)) u,
          ];
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && ask == _asked) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: widget.title,
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                ),
                onChanged: _search,
              ),
            ),
            if (_error != null) ListTile(title: Text('$_error')),
            Expanded(
              child: ListView(
                children: [
                  for (final u in _found)
                    ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.person_outline),
                      ),
                      title: Text(u.name),
                      subtitle: u.email == null ? null : Text(u.email!),
                      onTap: () => Navigator.pop(context, u),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Who is in a channel; its manager can add and remove people.
class ChannelMembersScreen extends ConsumerStatefulWidget {
  const ChannelMembersScreen({
    super.key,
    required this.api,
    required this.channel,
  });
  final ChannelsApi api;
  final Channel channel;

  @override
  ConsumerState<ChannelMembersScreen> createState() =>
      _ChannelMembersScreenState();
}

class _ChannelMembersScreenState extends ConsumerState<ChannelMembersScreen> {
  late Future<List<ChannelMember>> _members = widget.api.members(
    widget.channel.id,
  );

  Future<List<ServerApp>> _apps = Future.value(const []);

  /// Set from the server's features as the screen builds.
  bool _appsOn = false;

  Future<List<ServerApp>> _loadApps() async {
    if (!_appsOn) return const [];
    return [
      for (final a in await widget.api.apps(widget.channel.id)) ServerApp(a),
    ];
  }

  void _reload() => setState(() {
    _members = widget.api.members(widget.channel.id);
    _apps = _loadApps();
  });

  /// Invites an app the user can use and that hasn't joined yet.
  Future<void> _addApp(List<ServerApp> joined) async {
    final List<ServerApp> all;
    try {
      all = await AppsApi(widget.api.client).list();
    } catch (e) {
      if (mounted) _say(context, '$e');
      return;
    }
    final have = {for (final a in joined) a.id};
    final open = [
      for (final a in all)
        if (a.active && a.configured && !have.contains(a.id)) a,
    ];
    if (!mounted) return;
    if (open.isEmpty) {
      _say(context, 'No other apps to add');
      return;
    }
    final pick = await showModalBottomSheet<ServerApp>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final a in open)
              ListTile(
                leading: _AppAvatar(a),
                title: Text(a.name),
                subtitle: _appBlurb(a),
                onTap: () => Navigator.pop(context, a),
              ),
          ],
        ),
      ),
    );
    if (pick == null) return;
    try {
      await widget.api.inviteApp(widget.channel.id, pick.id);
      _reload();
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  Future<void> _removeApp(ServerApp a) async {
    try {
      await widget.api.removeApp(widget.channel.id, a.id);
      _reload();
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  Widget _appsSection(bool manage) => FutureBuilder<List<ServerApp>>(
    future: _apps,
    builder: (context, snap) {
      final apps = snap.data ?? const <ServerApp>[];
      if (!_appsOn || (apps.isEmpty && !manage)) {
        return const SizedBox.shrink();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: T('Apps', style: Theme.of(context).textTheme.titleSmall),
          ),
          if (manage)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.apps)),
              title: const T('Add an app'),
              onTap: snap.hasData ? () => _addApp(apps) : null,
            ),
          for (final a in apps)
            ListTile(
              leading: _AppAvatar(a),
              title: Text(a.name),
              subtitle: _appBlurb(a),
              trailing: manage
                  ? IconButton(
                      tooltip: tr('Remove app'),
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => _removeApp(a),
                    )
                  : null,
            ),
        ],
      );
    },
  );

  Future<void> _add(List<ChannelMember> now) async {
    final u = await pickPerson(
      context,
      widget.api,
      skip: {for (final m in now) m.id},
    );
    if (u == null) return;
    try {
      await widget.api.addMembers(widget.channel.id, [u.id]);
      _reload();
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  Future<void> _remove(ChannelMember u) async {
    try {
      await widget.api.removeMembers(widget.channel.id, [u.id]);
      _reload();
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final manage = canManage(ref, widget.channel) && !widget.channel.isDm;
    final appsOn =
        !widget.channel.isDm &&
        (ref.watch(serverConfigProvider).value?['features']
                as Map?)?['enable_apps'] ==
            true;
    if (appsOn != _appsOn) {
      _appsOn = appsOn;
      _apps = _loadApps();
    }
    final me = ref.read(sessionProvider).value?.user?['id'];
    return Scaffold(
      appBar: AppBar(title: const T('Members')),
      body: FutureBuilder<List<ChannelMember>>(
        future: _members,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Text('Couldn\'t load members.\n${snap.error}'),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;
          return ListView(
            children: [
              if (manage)
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person_add)),
                  title: const T('Add people'),
                  onTap: () => _add(list),
                ),
              for (final u in list)
                ListTile(
                  leading: CircleAvatar(
                    child: Text(u.name.isEmpty ? '?' : u.name.characters.first),
                  ),
                  title: Text(u.id == me ? '${u.name} (you)' : u.name),
                  subtitle: u.email == null ? null : Text(u.email!),
                  trailing: manage && u.id != widget.channel.ownerId
                      ? IconButton(
                          tooltip: tr('Remove'),
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: () => _remove(u),
                        )
                      : null,
                ),
              _appsSection(manage),
            ],
          );
        },
      ),
    );
  }
}

Widget? _appBlurb(ServerApp a) {
  final d = a.manifest?['description'];
  return d is String && d.isNotEmpty
      ? Text(d, maxLines: 2, overflow: TextOverflow.ellipsis)
      : null;
}

class _AppAvatar extends StatelessWidget {
  const _AppAvatar(this.app);
  final ServerApp app;

  @override
  Widget build(BuildContext context) {
    final img = app.image;
    final letter = Text(app.name.isEmpty ? '?' : app.name.characters.first);
    if (img == null || !img.startsWith('http') && !img.startsWith('data:')) {
      return CircleAvatar(child: letter);
    }
    return CircleAvatar(
      foregroundImage: img.startsWith('data:')
          ? MemoryImage(UriData.parse(img).contentAsBytes())
          : NetworkImage(img) as ImageProvider,
      child: letter,
    );
  }
}

/// A channel's webhooks: addresses other services post messages to.
class ChannelWebhooksScreen extends StatefulWidget {
  const ChannelWebhooksScreen({
    super.key,
    required this.api,
    required this.channel,
  });
  final ChannelsApi api;
  final Channel channel;

  @override
  State<ChannelWebhooksScreen> createState() => _ChannelWebhooksScreenState();
}

class _ChannelWebhooksScreenState extends State<ChannelWebhooksScreen> {
  late Future<List<ChannelWebhook>> _hooks = widget.api.webhooks(
    widget.channel.id,
  );

  String get _base => widget.api.client.baseUrl;

  void _reload() =>
      setState(() => _hooks = widget.api.webhooks(widget.channel.id));

  Future<void> _create() async {
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const T('New webhook'),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('Name'),
            hintText: tr('Shown as the sender'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const T('Create'),
          ),
        ],
      ),
    );
    final text = name.text.trim();
    // Not disposed: the dialog's text field still builds while it closes.
    if (ok != true || text.isEmpty) return;
    try {
      final hook = await widget.api.createWebhook(widget.channel.id, text);
      await Clipboard.setData(ClipboardData(text: hook.url(_base)));
      if (mounted) _say(context, 'Webhook made; its address is copied');
      _reload();
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  Future<void> _delete(ChannelWebhook h) async {
    try {
      await widget.api.deleteWebhook(widget.channel.id, h.id);
      _reload();
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(title: const T('Webhooks')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const T('New webhook'),
      ),
      body: FutureBuilder<List<ChannelWebhook>>(
        future: _hooks,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Text('Couldn\'t load webhooks.\n${snap.error}'),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Other services post into #${widget.channel.name} by '
                  'sending {"content": "…"} to a webhook\'s address.',
                  style: TextStyle(color: muted),
                ),
              ),
              for (final h in list)
                ListTile(
                  leading: const Icon(Icons.webhook_outlined),
                  title: Text(h.name),
                  subtitle: Text(
                    [?h.createdLabel, h.url(_base)].join('\n'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: h.url(_base)));
                    if (context.mounted) _say(context, 'Address copied');
                  },
                  trailing: IconButton(
                    tooltip: tr('Delete'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(h),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
