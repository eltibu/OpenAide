/// Admin > Apps, as the web's: outside apps that join channels (a bot on
/// your own server, say). Add one by its address and key (its details come
/// from it, or are typed in), review the scopes it asks for, choose who
/// can use it, connect, switch off, and uninstall.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../workspace/access_editor.dart';

/// What each scope lets an app do, as the web says it.
const appScopes = {
  'channels:mentions:read': 'Read app mentions in joined channels',
  'channels:messages:read': 'Read messages and history in joined channels',
  'channels:messages:write':
      'Send messages and edit own messages in joined channels',
  'channels:read': 'Read joined channel details',
};

/// An installed app, as the server lists it.
class ServerApp {
  ServerApp(this.raw);
  final Map<String, dynamic> raw;

  String get id => '${raw['id']}';
  String get slug => '${raw['slug'] ?? ''}';
  String get name => '${raw['name'] ?? ''}';
  bool get active => raw['is_active'] == true;

  /// False once uninstalled: its key is gone until it's connected again.
  bool get configured => raw['configured'] == true;
  String get status => '${raw['connection_status'] ?? 'disconnected'}';
  Map<String, dynamic> get data =>
      (raw['data'] as Map?)?.cast<String, dynamic>() ?? const {};
  String get url => '${data['url'] ?? ''}';
  Map<String, dynamic>? get manifest =>
      (data['manifest'] as Map?)?.cast<String, dynamic>();
  List<String> get grantedScopes => [
    for (final s in data['granted_scopes'] as List? ?? const []) '$s',
  ];
  String? get image => manifest?['profile_image_url'] as String?;
}

/// A slug from an app's id, as the web makes one.
String appSlug(String id) {
  final s = id
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9-]'), '-')
      .replaceFirst(RegExp('^[^a-z]+'), '');
  return s.isEmpty ? 'app' : (s.length > 40 ? s.substring(0, 40) : s);
}

/// How the list says where an app is.
String appState(ServerApp app) {
  if (!app.configured) return 'Uninstalled';
  if (!app.active) return 'Disabled';
  return switch (app.status) {
    'connected' => 'Connected',
    'connecting' => 'Connecting',
    _ => 'Disconnected',
  };
}

class AppsApi {
  AppsApi(this.client);
  final OpenWebUiClient client;

  Future<List<ServerApp>> list() async => [
    for (final a in await client.send('GET', '/api/v1/apps') as List? ?? [])
      if (a is Map) ServerApp(a.cast<String, dynamic>()),
  ];

  /// With its access grants.
  Future<ServerApp> get(String id) async => ServerApp(
    (await client.send('GET', '/api/v1/apps/$id') as Map)
        .cast<String, dynamic>(),
  );

  /// The details the app at [url] gives about itself.
  Future<Map<String, dynamic>> preview(
    String url, {
    String? apiKey,
    String? appId,
  }) async => (await client.send(
    'POST',
    '/api/v1/apps/manifest/preview',
    body: {
      'url': url,
      if (apiKey != null && apiKey.isNotEmpty) 'api_key': apiKey,
      'app_id': ?appId,
    },
  ) as Map).cast<String, dynamic>();

  Future<ServerApp> create({
    required Map<String, dynamic> manifest,
    required String url,
    required String apiKey,
    required String slug,
    required List<String> scopes,
    required List<Grant> grants,
  }) async => ServerApp(
    (await client.send(
      'POST',
      '/api/v1/apps',
      body: {
        'manifest': manifest,
        'url': url,
        'api_key': apiKey,
        'slug': slug,
        'granted_scopes': scopes,
        'access_grants': writeGrants(grants),
      },
    ) as Map).cast<String, dynamic>(),
  );

  Future<ServerApp> update(
    String id, {
    bool? active,
    String? name,
    List<String>? scopes,
    List<Grant>? grants,
    Map<String, dynamic>? manifest,
  }) async => ServerApp(
    (await client.send(
      'PATCH',
      '/api/v1/apps/$id',
      body: {
        'is_active': ?active,
        'name': ?name,
        'granted_scopes': ?scopes,
        if (grants != null) 'access_grants': writeGrants(grants),
        'manifest': ?manifest,
      },
    ) as Map).cast<String, dynamic>(),
  );

  /// Connects (and so switches on) the app, with a new key if given.
  Future<ServerApp> connect(String id, {String? apiKey}) async => ServerApp(
    (await client.send(
      'POST',
      '/api/v1/apps/$id/connect',
      body: {if (apiKey != null && apiKey.isNotEmpty) 'api_key': apiKey},
    ) as Map).cast<String, dynamic>(),
  );

  Future<void> uninstall(String id) =>
      client.send('DELETE', '/api/v1/apps/$id');
}

final appsApiProvider = Provider((ref) => AppsApi(ref.watch(clientProvider)));

/// An app's picture (a link or a data: image), or the grid icon.
Widget appImage(String? src, {double size = 32}) {
  Widget fallback() => Icon(Icons.apps, size: size * 0.75);
  if (src == null || src.isEmpty) return fallback();
  final Widget image;
  if (src.startsWith('data:')) {
    try {
      image = Image.memory(
        base64Decode(src.substring(src.indexOf(',') + 1)),
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    } catch (_) {
      return fallback();
    }
  } else {
    image = Image.network(
      src,
      width: size,
      height: size,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => fallback(),
    );
  }
  return ClipRRect(borderRadius: BorderRadius.circular(6), child: image);
}

class AppsScreen extends ConsumerStatefulWidget {
  const AppsScreen({super.key});

  @override
  ConsumerState<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends ConsumerState<AppsScreen> {
  List<ServerApp>? _apps;
  Object? _error;
  String _busy = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // Connection state changes on its own, so look again now and then.
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load(true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load([bool quiet = false]) async {
    try {
      final apps = await ref.read(appsApiProvider).list();
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _error = null;
      });
    } catch (e) {
      if (mounted && !quiet) setState(() => _error = e);
    }
  }

  Future<void> _configure([ServerApp? app]) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => AppEditor(app: app)),
    );
    if (changed == true) await _load();
  }

  Future<void> _toggle(ServerApp app) async {
    // Switching on means connecting, which the editor does.
    if (!app.active) return _configure(app);
    setState(() => _busy = app.id);
    try {
      await ref.read(appsApiProvider).update(app.id, active: false);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) setState(() => _busy = '');
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final apps = _apps;
    final error = _error;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Apps'),
        actions: [
          IconButton(
            tooltip: 'Add app',
            icon: const Icon(Icons.add),
            onPressed: error == null ? () => _configure() : null,
          ),
        ],
      ),
      body: error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  error is ApiException && error.statusCode == 404
                      ? 'Apps are off. Turn them on in Admin > General.'
                      : "Couldn't load the apps.\n$error",
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : apps == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Text(
                      'Outside apps that join channels, such as a bot on your '
                      'own server. Experimental, as on the web.',
                      style: TextStyle(color: muted),
                    ),
                  ),
                  if (apps.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No apps yet. Tap + to add one.',
                        style: TextStyle(color: muted),
                      ),
                    ),
                  for (final app in apps)
                    Opacity(
                      opacity: app.active ? 1 : 0.6,
                      child: ListTile(
                        leading: appImage(app.image),
                        title: Text(app.name),
                        subtitle: Text(appState(app)),
                        onTap: () => _configure(app),
                        trailing: _busy == app.id
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Switch(
                                value: app.active,
                                onChanged: (_) => _toggle(app),
                              ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

/// Adding or changing an app; pops true when something was saved.
class AppEditor extends ConsumerStatefulWidget {
  const AppEditor({super.key, this.app});
  final ServerApp? app;

  @override
  ConsumerState<AppEditor> createState() => _AppEditorState();
}

class _AppEditorState extends ConsumerState<AppEditor> {
  late ServerApp? _app = widget.app;
  late final _url = TextEditingController(text: widget.app?.url ?? '');
  final _key = TextEditingController();
  late final _name = TextEditingController(text: widget.app?.name ?? '');
  late final _slug = TextEditingController(text: widget.app?.slug ?? '');
  final _id = TextEditingController();
  final _publicKey = TextEditingController();

  /// The app's details: from it (Continue) or typed in (manual).
  late Map<String, dynamic>? _manifest = widget.app?.manifest == null
      ? null
      : {...widget.app!.manifest!};
  late final Set<String> _scopes = {...?widget.app?.grantedScopes};
  late Set<String> _requested = {
    for (final s in _manifest?['requested_scopes'] as List? ?? const []) '$s',
  };
  List<Grant> _grants = const [(type: 'user', id: '*', permission: 'read')];
  bool _manual = false;
  bool _manifestChanged = false;
  bool _hideKey = true;
  bool _busy = false;
  bool _changed = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    final app = _app;
    if (app != null) {
      _grants = const [];
      _run(() async {
        final full = await ref.read(appsApiProvider).get(app.id);
        _grants = readGrants(full.raw['access_grants']);
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_url, _key, _name, _slug, _id, _publicKey]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() task) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await task();
    } on ApiException catch (e) {
      _problem = e.message;
    } catch (e) {
      _problem = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  void _editManually() => setState(() {
    _manual = true;
    final m = _manifest ??= {
      'id': '',
      'name': '',
      'public_key': '',
      'requested_scopes': <String>[],
    };
    _id.text = '${m['id'] ?? ''}';
    _publicKey.text = '${m['public_key'] ?? ''}';
    _requested = {for (final s in m['requested_scopes'] as List? ?? []) '$s'};
    _manifestChanged = _app != null;
  });

  /// Asks the app for its details.
  Future<void> _fetch() => _run(() async {
    final m = await ref
        .read(appsApiProvider)
        .preview(_url.text.trim(), apiKey: _key.text.trim(), appId: _app?.id);
    _manifest = m;
    _manual = false;
    _requested = {for (final s in m['requested_scopes'] as List? ?? []) '$s'};
    if (_app == null) {
      _name.text = '${m['name'] ?? ''}';
      _slug.text = appSlug('${m['id'] ?? ''}');
      _scopes
        ..clear()
        ..addAll(_requested);
    } else {
      // A changed app is saved only after its scopes are looked at again.
      _manifestChanged =
          jsonEncode(m) != jsonEncode(_app!.manifest ?? const {});
      _scopes.retainAll(_requested);
    }
  });

  Future<void> _save() => _run(() async {
    final api = ref.read(appsApiProvider);
    var manifest = {..._manifest!};
    if (_manual) {
      manifest = {
        ...manifest,
        'id': _id.text.trim().isEmpty ? _slug.text.trim() : _id.text.trim(),
        'name': _app == null ? _name.text.trim() : manifest['name'],
        'public_key': _publicKey.text.trim(),
        'requested_scopes': [..._requested],
      };
      _manifestChanged =
          _app != null &&
          jsonEncode(manifest) != jsonEncode(_app!.manifest ?? const {});
    }
    final scopes = [
      for (final s in _scopes)
        if (_requested.contains(s)) s,
    ];
    var app = _app;
    if (app == null) {
      app = await api.create(
        manifest: {...manifest, 'name': _name.text.trim()},
        url: _url.text.trim(),
        apiKey: _key.text.trim(),
        slug: _slug.text.trim(),
        scopes: scopes,
        grants: _grants,
      );
      _app = app;
      _changed = true;
    } else {
      app = await api.update(
        app.id,
        name: _name.text.trim(),
        scopes: scopes,
        grants: _grants,
        manifest: _manifestChanged ? manifest : null,
      );
      _app = app;
      _changed = true;
      _manifestChanged = false;
    }
    if (!app.active || _key.text.trim().isNotEmpty) {
      _app = await api.connect(app.id, apiKey: _key.text.trim());
    }
    if (mounted) Navigator.pop(context, true);
  });

  Future<void> _uninstall() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Uninstall ${_app!.name}?'),
        content: const Text(
          'It is disconnected, its key is removed and it leaves its '
          'channels. You can connect it again later with a key.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Uninstall'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await ref.read(appsApiProvider).uninstall(_app!.id);
      if (mounted) Navigator.pop(context, true);
    });
  }

  Future<void> _access() async {
    final grants = await Navigator.push<List<Grant>>(
      context,
      MaterialPageRoute(
        builder: (_) => AccessEditor(
          kind: 'app',
          id: _app?.id ?? '',
          name: _name.text.trim().isEmpty ? 'App' : _name.text.trim(),
          grants: _grants,
        ),
      ),
    );
    if (grants != null) setState(() => _grants = grants);
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final app = _app;
    final manifest = _manifest;
    final everyone = _grants.any((g) => g.type == 'user' && g.id == '*');
    final ready =
        manifest != null &&
        _url.text.trim().isNotEmpty &&
        (app != null || _key.text.trim().isNotEmpty) &&
        _name.text.trim().isNotEmpty &&
        _slug.text.trim().isNotEmpty;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Close app settings',
            icon: const Icon(Icons.close),
            onPressed: _busy ? null : () => Navigator.pop(context, _changed),
          ),
          title: Text(app == null ? 'Add app' : 'Configure app'),
          actions: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: manifest == null
                  ? FilledButton(
                      onPressed: _busy || _url.text.trim().isEmpty
                          ? null
                          : _fetch,
                      child: const Text('Continue'),
                    )
                  : FilledButton(
                      onPressed: _busy || !ready ? null : _save,
                      child: Text(
                        app == null
                            ? 'Add app'
                            : app.active && _key.text.trim().isEmpty
                            ? 'Save'
                            : 'Connect',
                      ),
                    ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (app != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: appImage(app.image, size: 40),
                title: Text(app.name),
                subtitle: Text(appState(app)),
              ),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _problem!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Text(
              'Connection',
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(color: NexusColors.accent),
            ),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              // An installed app keeps its address.
              enabled: app == null,
              decoration: const InputDecoration(
                labelText: 'App URL',
                hintText: 'https://app.example.com/openwebui',
              ),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _key,
              obscureText: _hideKey,
              decoration: InputDecoration(
                labelText: 'API Key',
                helperText: app == null
                    ? 'Enter the API key provided by the app.'
                    : 'Leave empty to keep the current API key.',
                suffixIcon: IconButton(
                  tooltip: _hideKey ? 'Show' : 'Hide',
                  icon: Icon(
                    _hideKey ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _hideKey = !_hideKey),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            Row(
              children: [
                if (manifest != null && !_manual)
                  TextButton.icon(
                    onPressed: _busy || _url.text.trim().isEmpty
                        ? null
                        : _fetch,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check for changes'),
                  ),
                if (!_manual)
                  TextButton(
                    onPressed: _busy ? null : _editManually,
                    child: Text(
                      manifest == null
                          ? 'Enter details manually'
                          : 'Edit details manually',
                    ),
                  ),
              ],
            ),
            if (manifest != null) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                controller: _slug,
                enabled: app == null,
                decoration: const InputDecoration(
                  labelText: 'App handle',
                  helperText: 'How people mention it, like @my-app',
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (_manual) ...[
                TextField(
                  controller: _id,
                  enabled: app == null,
                  decoration: const InputDecoration(
                    labelText: 'App ID',
                    helperText: 'Left empty, the handle is used',
                  ),
                ),
                TextField(
                  controller: _publicKey,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Public key',
                    helperText:
                        'Enter the Ed25519 public key provided by the app.',
                  ),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 12),
                Text('Requested scopes', style: TextStyle(color: muted)),
                for (final MapEntry(:key, :value) in appScopes.entries)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(value),
                    subtitle: Text(key, style: const TextStyle(fontSize: 11)),
                    value: _requested.contains(key),
                    onChanged: (on) => setState(() {
                      on == true ? _requested.add(key) : _requested.remove(key);
                      if (on == true && app == null) _scopes.add(key);
                    }),
                  ),
              ],
              const SizedBox(height: 16),
              Text(
                'App scopes',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(color: NexusColors.accent),
              ),
              Text(
                _manifestChanged
                    ? 'Saving approves the updated app identity and selected '
                          'scopes.'
                    : app == null
                    ? 'Review the scopes this app is requesting before adding '
                          'it.'
                    : 'What the app may do.',
                style: TextStyle(color: muted),
              ),
              if (_requested.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No scopes requested.',
                    style: TextStyle(color: muted),
                  ),
                ),
              for (final s in _requested)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(appScopes[s] ?? s),
                  subtitle: Text(s, style: const TextStyle(fontSize: 11)),
                  value: _scopes.contains(s),
                  onChanged: (on) =>
                      setState(() => on ? _scopes.add(s) : _scopes.remove(s)),
                ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(everyone ? Icons.public : Icons.lock_outline),
                title: const Text('Access'),
                subtitle: Text(
                  everyone
                      ? 'Everyone'
                      : _grants.isEmpty
                      ? 'Only admins can use this app. Add users or groups '
                            'to allow others.'
                      : 'Restricted',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : _access,
              ),
            ],
            if (app != null && app.configured) ...[
              const Divider(height: 32),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: _busy ? null : _uninstall,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Uninstall app'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
