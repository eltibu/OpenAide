import 'apps_screen.dart';
import 'arena_screen.dart';
import 'events_screen.dart';

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart' show serverConfigProvider;
import '../server/server_page.dart';
import '../settings/settings_screen.dart' show Avatar;
import '../workspace/tools_skills.dart' show ValvesScreen;
import '../workspace/version_history.dart';
import 'admin_api.dart';
import 'admin_models_screen.dart';
import 'analytics_screen.dart';
import 'banners_screen.dart';
import 'config_editor.dart';
import 'evaluations_screen.dart';
import 'connections_screen.dart';
import 'groups_screen.dart';
import 'integrations_screen.dart';
import 'pipelines_screen.dart';
import 'user_extras.dart';
import '../workspace/code_editor.dart';
import '../../core/widgets/search_field.dart';

final adminApiProvider = Provider<AdminApi>(
  (ref) => AdminApi(ref.watch(clientProvider)),
);

final adminUsersProvider = FutureProvider.family<List<AdminUser>, String>(
  (ref, query) => ref.watch(adminApiProvider).users(query: query),
);

final functionsProvider = FutureProvider<List<ServerFunction>>(
  (ref) => ref.watch(adminApiProvider).functions(),
);

const _sectionIcons = {
  'Documents': Icons.description_outlined,
  'Web Search': Icons.travel_explore,
  'Audio': Icons.graphic_eq,
  'Images': Icons.image_outlined,
  'Code Execution': Icons.code,
  'Interface and tasks': Icons.view_quilt_outlined,
  'Connections': Icons.cable,
  'Evaluations': Icons.leaderboard_outlined,
  'Embedding': Icons.scatter_plot_outlined,
  'Database': Icons.storage_outlined,
  'Sign-in and features': Icons.login,
  'OAuth / OIDC': Icons.key_outlined,
  'LDAP': Icons.account_tree_outlined,
  'LDAP server': Icons.dns_outlined,
  'Subagents': Icons.hub_outlined,
};

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// The Admin Panel: people, site switches, functions and the server's
/// settings pages are native; what isn't yet opens as the server's page.
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void open(Widget page) =>
        Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
    return Scaffold(
      appBar: AppBar(title: const Text('Admin Panel')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('Users'),
            subtitle: const Text('Accounts, roles and passwords'),
            onTap: () => open(const UsersScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.groups_outlined),
            title: const Text('Groups and permissions'),
            subtitle: const Text(
              'What everyone may do, and groups that give more',
            ),
            onTap: () => open(const GroupsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.insights_outlined),
            title: const Text('Analytics'),
            subtitle: const Text('Messages, models, people and tokens'),
            onTap: () => open(const AnalyticsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.emoji_events_outlined),
            title: const Text('Leaderboard and feedback'),
            subtitle: const Text('How people rate the models'),
            onTap: () => open(const EvaluationsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.casino_outlined),
            title: const Text('Evaluations'),
            subtitle: const Text('Arena models for blind comparisons'),
            onTap: () => open(const ArenaScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.toggle_on_outlined),
            title: const Text('General'),
            subtitle: const Text('Sign-ups, features and sessions'),
            onTap: () => open(const AdminGeneral()),
          ),
          ListTile(
            leading: const Icon(Icons.functions),
            title: const Text('Functions'),
            subtitle: const Text('Filters, pipes and actions'),
            onTap: () => open(const FunctionsScreen()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.campaign_outlined),
            title: const Text('Banners'),
            subtitle: const Text('Notices shown to everyone'),
            onTap: () => open(const BannersScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('Models'),
            subtitle: const Text(
              'Switch on, hide, set up, order and set defaults',
            ),
            onTap: () => open(const AdminModelsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.cable),
            title: const Text('Model connections'),
            subtitle: const Text('OpenAI-compatible and Ollama servers'),
            onTap: () => open(const ConnectionsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: const Text('Integrations'),
            subtitle: const Text('Tool servers (OpenAPI, MCP) and terminals'),
            onTap: () => open(const IntegrationsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.apps),
            title: const Text('Apps'),
            subtitle: const Text('Outside apps that join channels'),
            onTap: () => open(const AppsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.account_tree_outlined),
            title: const Text('Pipelines'),
            subtitle: const Text('Install, set up and remove pipelines'),
            onTap: () => open(const PipelinesScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.webhook),
            title: const Text('Events'),
            subtitle: const Text(
              'Webhooks the server calls when things happen',
            ),
            onTap: () => open(const EventsScreen()),
          ),
          for (final section in adminConfigSections)
            ListTile(
              leading: Icon(_sectionIcons[section.title] ?? Icons.tune),
              title: Text(section.title),
              subtitle: section.help == null ? null : Text(section.help!),
              onTap: () => open(ConfigEditorScreen(section: section)),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.settings_applications_outlined),
            title: const Text('More server settings'),
            subtitle: const Text('Everything else, on the web page'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => open(
              const ServerPage(
                title: 'Server settings',
                path: '/admin/settings',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Users ----

class UsersScreen extends ConsumerStatefulWidget {
  const UsersScreen({super.key});

  @override
  ConsumerState<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends ConsumerState<UsersScreen> {
  String _query = '';

  Future<void> _edit([AdminUser? user]) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => UserEditor(user: user)),
    );
    if (changed == true) ref.invalidate(adminUsersProvider);
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(adminUsersProvider(_query));
    final muted = context.nexus.muted;
    final me = ref.watch(sessionProvider).value?.user?['id'];
    return Scaffold(
      appBar: AppBar(title: const Text('Users')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add user',
        onPressed: _edit,
        child: const Icon(Icons.person_add_alt),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SearchField(
              hint: 'Search people',
              onSubmitted: (v) => setState(() => _query = v.trim()),
              onChanged: (v) {
                if (v.isEmpty) setState(() => _query = '');
              },
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.refresh(adminUsersProvider(_query).future),
              child: list.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Couldn\'t load users.\n$e'),
                    ),
                  ],
                ),
                data: (users) => ListView(
                  padding: const EdgeInsets.only(bottom: 88),
                  children: [
                    if (users.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No one matches.',
                          style: TextStyle(color: muted),
                        ),
                      ),
                    for (final u in users)
                      ListTile(
                        leading: Avatar(user: u.json),
                        title: Text(u.id == me ? '${u.name} (you)' : u.name),
                        subtitle: Text(
                          '${u.email}\nActive '
                          '${MaterialLocalizations.of(context).formatMediumDate(u.lastActive)}',
                          style: TextStyle(color: muted),
                        ),
                        isThreeLine: true,
                        trailing: _RoleChip(role: u.role),
                        onTap: () => _edit(u),
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
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role});
  final String role;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (role) {
      'admin' => scheme.primaryContainer,
      'pending' => scheme.errorContainer,
      _ => scheme.surfaceContainerHighest,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(role, style: Theme.of(context).textTheme.labelMedium),
    );
  }
}

class UserEditor extends ConsumerStatefulWidget {
  const UserEditor({super.key, this.user});
  final AdminUser? user;

  @override
  ConsumerState<UserEditor> createState() => _UserEditorState();
}

class _UserEditorState extends ConsumerState<UserEditor> {
  late final _name = TextEditingController(text: widget.user?.name);
  late final _email = TextEditingController(text: widget.user?.email);
  final _password = TextEditingController();
  late String _role = widget.user?.role ?? 'user';
  bool _busy = false;

  bool get _isNew => widget.user == null;

  Future<void> _save() async {
    final name = _name.text.trim();
    final email = _email.text.trim();
    if (name.isEmpty || email.isEmpty || (_isNew && _password.text.isEmpty)) {
      _say(
        context,
        _isNew
            ? 'Name, email and password are needed'
            : 'Name and email are needed',
      );
      return;
    }
    setState(() => _busy = true);
    final api = ref.read(adminApiProvider);
    try {
      if (_isNew) {
        await api.addUser(
          name: name,
          email: email,
          password: _password.text,
          role: _role,
        );
      } else {
        final u = widget.user!;
        await api.updateUser(
          u.id,
          name: name == u.name ? null : name,
          email: email == u.email ? null : email,
          role: _role == u.role ? null : _role,
          password: _password.text,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        _say(context, '$e');
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _delete() async {
    final u = widget.user!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${u.name}?'),
        content: const Text(
          'Their account and chats are removed from the server. This can\'t '
          'be undone.',
        ),
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
      await ref.read(adminApiProvider).deleteUser(u.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider).value?.user?['id'];
    final self = widget.user?.id == me;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Add user' : 'Edit user'),
        actions: [
          if (!_isNew && widget.user!.role != 'admin') ...[
            if ((ref.watch(serverConfigProvider).value?['features']
                    as Map?)?['enable_admin_chat_access'] !=
                false)
              IconButton(
                tooltip: 'Chats',
                icon: const Icon(Icons.forum_outlined),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => UserChatsScreen(
                      userId: widget.user!.id,
                      name: widget.user!.name,
                    ),
                  ),
                ),
              ),
            IconButton(
              tooltip: 'Preview Access',
              icon: const Icon(Icons.visibility_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => UserPreviewScreen(
                    userId: widget.user!.id,
                    name: widget.user!.name,
                  ),
                ),
              ),
            ),
          ],
          if (!_isNew && !self)
            IconButton(
              tooltip: 'Delete',
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_isNew ? 'Add' : 'Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SegmentedButton<String>(
            segments: [
              for (final r in userRoles)
                ButtonSegment(value: r, label: Text(r)),
            ],
            selected: {_role},
            // Your own role stays admin, so you can't lock yourself out.
            onSelectionChanged: self
                ? null
                : (s) => setState(() => _role = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          // Changing a password signs that person out everywhere, so your
          // own isn't changed from here.
          if (!self)
            TextField(
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: _isNew ? 'Password' : 'New password',
                helperText: _isNew ? null : 'Leave empty to keep theirs',
              ),
            ),
          if (!_isNew) ...[
            const SizedBox(height: 16),
            Text(
              'Joined ${MaterialLocalizations.of(context).formatMediumDate(widget.user!.created)}',
              style: TextStyle(color: context.nexus.muted),
            ),
            // Not for yourself: it would sign this phone out too.
            if (!self)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out all devices'),
                  onPressed: _busy ? null : _signOutEverywhere,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _signOutEverywhere() async {
    final u = widget.user!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Sign out all devices?'),
        content: Text(
          '${u.name} will need to sign in again on every device. API keys '
          'remain active.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(clientProvider)
          .send(
            'POST',
            '/api/v1/users/${Uri.encodeComponent(u.id)}/sessions/revoke',
          );
      if (mounted) _say(context, 'All sessions revoked');
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }
}

// ---- General ----

class AdminGeneral extends ConsumerStatefulWidget {
  const AdminGeneral({super.key});

  @override
  ConsumerState<AdminGeneral> createState() => _AdminGeneralState();
}

class _AdminGeneralState extends ConsumerState<AdminGeneral> {
  Map<String, dynamic>? _config;
  final _url = TextEditingController();
  final _jwt = TextEditingController();
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await ref.read(adminApiProvider).config();
      if (!mounted) return;
      setState(() {
        _config = c;
        _url.text = '${c['WEBUI_URL'] ?? ''}';
        _jwt.text = '${c['JWT_EXPIRES_IN'] ?? ''}';
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    final c = {..._config!, 'WEBUI_URL': _url.text.trim()};
    c['JWT_EXPIRES_IN'] = _jwt.text.trim();
    setState(() => _busy = true);
    try {
      final saved = await ref.read(adminApiProvider).saveConfig(c);
      if (mounted) {
        setState(() => _config = saved);
        _say(context, 'Saved');
      }
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = _config;
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const Text('General'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: c == null || _busy ? null : _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: c == null
          ? Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Couldn\'t load the settings.\n$_error'),
                    )
                  : const CircularProgressIndicator(),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: DropdownButtonFormField<String>(
                    initialValue: userRoles.contains(c['DEFAULT_USER_ROLE'])
                        ? c['DEFAULT_USER_ROLE'] as String
                        : 'pending',
                    decoration: const InputDecoration(
                      labelText: 'New accounts start as',
                    ),
                    items: [
                      for (final r in userRoles)
                        DropdownMenuItem(value: r, child: Text(r)),
                    ],
                    onChanged: (v) =>
                        setState(() => c['DEFAULT_USER_ROLE'] = v),
                  ),
                ),
                for (final (key, label, hint) in adminSwitches)
                  if (c.containsKey(key))
                    SwitchListTile(
                      title: Text(label),
                      subtitle: hint.isEmpty
                          ? null
                          : Text(hint, style: TextStyle(color: muted)),
                      value: c[key] == true,
                      onChanged: (on) => setState(() => c[key] = on),
                    ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Column(
                    children: [
                      TextField(
                        controller: _url,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Server address',
                          helperText: 'Used in links and sign-in redirects',
                        ),
                      ),
                      TextField(
                        controller: _jwt,
                        decoration: const InputDecoration(
                          labelText: 'Sign-ins last',
                          helperText: 'Like 4w, 7d or 12h; -1 for never ending',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

// ---- Functions ----

/// Opens the function code editor; true when saved.
Future<bool> editFunction(
  BuildContext context, {
  String? id,
  Map<String, dynamic>? start,
}) async =>
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CodeItemEditor(kind: 'function', id: id, start: start),
      ),
    ) ==
    true;

class FunctionsScreen extends ConsumerWidget {
  const FunctionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(functionsProvider);
    final muted = context.nexus.muted;
    Future<void> run(Future<void> Function() action) async {
      try {
        await action();
      } catch (e) {
        if (context.mounted) _say(context, '$e');
      }
      ref.invalidate(functionsProvider);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Functions'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'New Function',
            icon: const Icon(Icons.add),
            onSelected: (v) async {
              final saved = v == 'url'
                  ? await importCodeFromUrl(context, ref, 'function')
                  : await editFunction(context);
              if (saved) ref.invalidate(functionsProvider);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'new', child: Text('New Function')),
              PopupMenuItem(value: 'url', child: Text('Import from URL')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(functionsProvider.future),
        child: list.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load functions.\n$e'),
              ),
            ],
          ),
          data: (items) => ListView(
            children: [
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No functions yet. Tap + to write one or import it.',
                    style: TextStyle(color: muted),
                  ),
                ),
              for (final f in items)
                ExpansionTile(
                  leading: Icon(switch (f.type) {
                    'filter' => Icons.filter_alt_outlined,
                    'pipe' => Icons.alt_route,
                    'action' => Icons.touch_app_outlined,
                    _ => Icons.functions,
                  }),
                  title: Text(f.name),
                  subtitle: Text(
                    [
                      f.type,
                      if (f.description.isNotEmpty) f.description,
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: muted),
                  ),
                  trailing: Switch(
                    value: f.active,
                    onChanged: (_) => run(
                      () => ref.read(adminApiProvider).toggleFunction(f.id),
                    ),
                  ),
                  children: [
                    if (f.type != 'pipe')
                      SwitchListTile(
                        title: const Text('For all models'),
                        subtitle: const Text(
                          'Runs on every model, not just ones that pick it',
                        ),
                        value: f.global,
                        onChanged: (_) => run(
                          () => ref
                              .read(adminApiProvider)
                              .toggleFunctionGlobal(f.id),
                        ),
                      ),
                    ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: const Text('Edit'),
                      onTap: () async {
                        if (await editFunction(context, id: f.id)) {
                          ref.invalidate(functionsProvider);
                        }
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.copy_all_outlined),
                      title: const Text('Clone'),
                      onTap: () => run(() async {
                        final one =
                            ((await ref
                                        .read(clientProvider)
                                        .send(
                                          'GET',
                                          '/api/v1/functions/id/${f.id}',
                                        ))
                                    as Map)
                                .cast<String, dynamic>();
                        if (!context.mounted) return;
                        await editFunction(
                          context,
                          start: {
                            ...one,
                            'name': '${one['name'] ?? f.name} (copy)',
                          },
                        );
                      }),
                    ),
                    ListTile(
                      leading: const Icon(Icons.tune),
                      title: const Text('Settings'),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ValvesScreen(
                            title: f.name,
                            specPath:
                                '/api/v1/functions/id/${f.id}/valves/spec',
                            valuesPath: '/api/v1/functions/id/${f.id}/valves',
                            savePath:
                                '/api/v1/functions/id/${f.id}/valves/update',
                          ),
                        ),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.history),
                      title: const Text('Version history'),
                      onTap: () async {
                        final changed = await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => VersionHistoryScreen(
                              kind: 'function',
                              id: f.id,
                              name: f.name,
                            ),
                          ),
                        );
                        if (changed == true) ref.invalidate(functionsProvider);
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.ios_share),
                      title: const Text('Export'),
                      onTap: () => run(() async {
                        final one = await ref
                            .read(clientProvider)
                            .send('GET', '/api/v1/functions/id/${f.id}');
                        await FilePicker.saveFile(
                          fileName: 'function-${f.id}-export.json',
                          bytes: utf8.encode(jsonEncode([one])),
                        );
                      }),
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.delete_outline,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      title: const Text('Delete'),
                      onTap: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (d) => AlertDialog(
                            title: Text('Delete ${f.name}?'),
                            content: const Text('This can\'t be undone.'),
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
                        if (ok == true) {
                          await run(
                            () =>
                                ref.read(adminApiProvider).deleteFunction(f.id),
                          );
                        }
                      },
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
