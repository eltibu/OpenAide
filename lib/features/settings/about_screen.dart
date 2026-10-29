/// Settings > About, as the web's: the server's Open WebUI version and
/// whether a newer one is out, What's New (the release notes), and the
/// Ollama version. Admins also get What's New once after the server is
/// updated, and a note when a newer Open WebUI is out, as on the web.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../../core/i18n/app_strings.dart';
import '../chat/chat_controller.dart'
    show serverConfigProvider, userSettingsProvider;
import 'settings_screen.dart'
    show meProvider, settingsApiProvider, uiSettingsProvider;

/// One release in the notes.
class ReleaseNotes {
  const ReleaseNotes(this.version, this.date, this.sections);
  final String version;
  final String date;

  /// Section ('added', 'fixed'...) and its entries, in the server's order.
  final List<(String, List<String>)> sections;
}

/// The server's changelog as [ReleaseNotes], newest first as it sends them.
List<ReleaseNotes> parseChangelog(Object? json) => [
  if (json is Map)
    for (final MapEntry(:key, :value) in json.entries)
      if (value is Map)
        ReleaseNotes('$key', '${value['date'] ?? ''}', [
          for (final s in value.entries)
            if (s.key != 'date' && s.value is List)
              (
                '${s.key}',
                [
                  for (final e in s.value as List)
                    if (e is Map && entryText(e).isNotEmpty) entryText(e),
                ],
              ),
        ]),
];

/// An entry's words: its HTML without the tags, else its plain content.
String entryText(Map entry) {
  final raw = '${entry['raw'] ?? ''}';
  final text = raw.isNotEmpty
      ? raw
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&#39;', "'")
      : '${entry['content'] ?? ''}';
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// "2026-10-25" as "Oct 25, 2026", as the web shows it.
String releaseDate(String date) {
  final p = date.split('-');
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final m = p.length == 3 ? int.tryParse(p[1]) : null;
  final d = p.length == 3 ? int.tryParse(p[2]) : null;
  if (m == null || d == null || m < 1 || m > 12) return date;
  return '${months[m - 1]} $d, ${p[0]}';
}

/// Whether [latest] is a newer version than [current] ("0.12.4" style).
bool isNewer(String latest, String current) {
  List<int> parts(String v) => [
    for (final p in v.replaceFirst(RegExp('^v'), '').split('.'))
      int.tryParse(RegExp(r'^\d+').stringMatch(p) ?? '') ?? 0,
  ];
  final a = parts(latest), b = parts(current);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Whether What's New opens by itself: for admins with the Interface
/// switch on, when the server's version isn't the one last seen.
bool showWhatsNewNow({
  required String? role,
  required Map? ui,
  required String? serverVersion,
}) =>
    role == 'admin' &&
    serverVersion != null &&
    ui?['showChangelog'] != false &&
    ui?['version'] != serverVersion;

/// The server's version and the newest out: (current, latest).
Future<(String, String)> versionUpdates(WidgetRef ref) async {
  final v =
      await ref.read(clientProvider).send('GET', '/api/version/updates') as Map;
  return ('${v['current'] ?? ''}', '${v['latest'] ?? ''}');
}

Uri releasePage(String version) => Uri.parse(
  'https://github.com/open-webui/open-webui/releases/tag/v$version',
);

/// What's New: the release notes. Seen once opened, as on the web.
class WhatsNewScreen extends ConsumerStatefulWidget {
  const WhatsNewScreen({super.key});

  @override
  ConsumerState<WhatsNewScreen> createState() => _WhatsNewScreenState();
}

class _WhatsNewScreenState extends ConsumerState<WhatsNewScreen> {
  late final Future<List<ReleaseNotes>> _notes = ref
      .read(clientProvider)
      .send('GET', '/api/changelog')
      .then(parseChangelog);

  @override
  void initState() {
    super.initState();
    _markSeen();
  }

  Future<void> _markSeen() async {
    try {
      final version =
          '${(await ref.read(serverConfigProvider.future))['version'] ?? ''}';
      if (version.isEmpty) return;
      await ref.read(settingsApiProvider).patchUi({'version': version});
      ref
        ..invalidate(uiSettingsProvider)
        ..invalidate(userSettingsProvider);
    } catch (_) {
      // It shows again next time; nothing else depends on it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final version = ref.watch(serverConfigProvider).value?['version'];
    return Scaffold(
      appBar: AppBar(
        title: const T("What's New"),
        leading: IconButton(
          tooltip: tr('Close'),
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const T("Okay, Let's Go!"),
          ),
        ),
      ),
      body: FutureBuilder(
        future: _notes,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  "Couldn't load the release notes.\n${snap.error}",
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final notes = snap.data;
          if (notes == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text(
                'Release notes${version == null ? '' : ' · v$version'}',
                style: TextStyle(color: muted),
              ),
              for (final r in notes) ...[
                const SizedBox(height: 20),
                Text(
                  'v${r.version}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  releaseDate(r.date),
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                for (final (section, entries) in r.sections)
                  if (entries.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      section.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 0.8,
                        color: switch (section) {
                          'added' => Colors.blue,
                          'fixed' => Colors.green,
                          'changed' => Colors.orange,
                          'removed' => Colors.red,
                          _ => muted,
                        },
                      ),
                    ),
                    for (final e in entries)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 7, right: 8),
                              child: Icon(Icons.circle, size: 5, color: muted),
                            ),
                            Expanded(child: SelectableText(e)),
                          ],
                        ),
                      ),
                  ],
              ],
            ],
          );
        },
      ),
    );
  }
}

class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  Future<(String, String)>? _updates;
  late final Future<String?> _ollama = ref
      .read(clientProvider)
      .send('GET', '/ollama/api/version')
      .then((v) => (v as Map?)?['version']?.toString())
      .catchError((Object _) => null);

  @override
  void initState() {
    super.initState();
    _check();
  }

  void _check() => setState(() {
    _updates = versionUpdates(ref);
  });

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final config = ref.watch(serverConfigProvider).value;
    final name = '${config?['name'] ?? 'Open WebUI'}';
    final version = '${config?['version'] ?? ''}';
    return Scaffold(
      appBar: AppBar(title: const T('About')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text('$name version'),
            subtitle: FutureBuilder(
              future: _updates,
              builder: (context, snap) {
                final v = version.isEmpty ? '' : 'v$version ';
                if (snap.hasError) {
                  return Text("${v}Couldn't check for updates");
                }
                final u = snap.data;
                if (u == null) return Text('${v}Checking for updates…');
                return isNewer(u.$2, u.$1.isEmpty ? version : u.$1)
                    ? Text('$v(v${u.$2} available!)')
                    : Text('$v(latest)');
              },
            ),
            trailing: IconButton(
              tooltip: tr('Check for updates'),
              icon: const Icon(Icons.refresh),
              onPressed: _check,
            ),
            onTap: () async {
              final u = await _updates?.catchError((Object _) => ('', ''));
              final to = u == null || u.$2.isEmpty ? version : u.$2;
              if (to.isNotEmpty) {
                await launchUrl(
                  releasePage(to),
                  mode: LaunchMode.externalApplication,
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const T("See what's new"),
            subtitle: const T("The server's release notes"),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const WhatsNewScreen()),
            ),
          ),
          FutureBuilder(
            future: _ollama,
            builder: (context, snap) => snap.data == null
                ? const SizedBox.shrink()
                : ListTile(
                    leading: const Icon(Icons.memory),
                    title: const T('Ollama version'),
                    subtitle: Text(snap.data!),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: T(
              'Open WebUI is made by Open WebUI Inc. and its community. '
              'OpenAide is a separate app that works with it.',
              style: TextStyle(color: muted, fontSize: 12),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const T('Open WebUI on GitHub'),
            onTap: () => launchUrl(
              Uri.parse('https://github.com/open-webui/open-webui'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          // The web's Community links.
          ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: const T('Community'),
            subtitle: const Text('Discord'),
            onTap: () => launchUrl(
              Uri.parse('https://discord.gg/5rJgQTnV4s'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.alternate_email),
            title: const Text('X'),
            subtitle: const Text('@OpenWebUI'),
            onTap: () => launchUrl(
              Uri.parse('https://twitter.com/OpenWebUI'),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ],
      ),
    );
  }
}

/// For admins, once after sign-in: What's New when the server was updated,
/// and a note when a newer Open WebUI is out (each with its Interface
/// switch, as on the web).
Future<void> adminStartupNotes(BuildContext context, WidgetRef ref) async {
  try {
    final me = await ref.read(meProvider.future);
    if (me['role'] != 'admin') return;
    final ui = await ref.read(uiSettingsProvider.future);
    final config = await ref.read(serverConfigProvider.future);
    final serverVersion = config['version']?.toString();
    if (!context.mounted) return;
    if (showWhatsNewNow(role: 'admin', ui: ui, serverVersion: serverVersion)) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => const WhatsNewScreen()),
      );
    }
    if (ui['showUpdateToast'] == false) return;
    final (current, latest) = await versionUpdates(ref);
    if (!context.mounted ||
        !isNewer(latest, current.isEmpty ? serverVersion ?? '' : current)) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 15),
        showCloseIcon: true,
        content: Text('A new Open WebUI (v$latest) is now available.'),
        action: SnackBarAction(
          label: 'See',
          onPressed: () => launchUrl(
            releasePage(latest),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ),
    );
  } catch (_) {
    // Offline or not allowed: nothing to say.
  }
}
