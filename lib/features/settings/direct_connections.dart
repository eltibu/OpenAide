/// Settings > Connections, as on the web: your own OpenAI-compatible
/// servers, kept with your settings on the server (ui.directConnections).
/// Their models join the model list; the phone itself talks to the server
/// when you chat with one, and passes the reply on to Open WebUI.
library;

import '../../core/widgets/empty_state.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/api/chat_socket.dart';
import '../../core/theme.dart';
import '../admin/connections_screen.dart';
import '../chat/chat_controller.dart';
import 'settings_screen.dart';

const directConnectionsKey = 'directConnections';

/// Your connections, when the admin allows them (else none).
List<Connection> directConnectionsOf(
  Map<String, dynamic>? settings,
  Map<String, dynamic>? config,
) {
  if ((config?['features'] as Map?)?['enable_direct_connections'] != true) {
    return const [];
  }
  final ui = settings?['ui'];
  final saved = ui is Map ? ui[directConnectionsKey] : null;
  return saved is Map ? readConnections(openAiConnections, saved) : const [];
}

Map<String, String> _auth(Connection c) => {
  if (c.config['auth_type'] != 'none' && c.key.isNotEmpty)
    'Authorization': 'Bearer ${c.key}',
};

/// The models [c] offers: its own list when it has one, else what its
/// /models answers.
Future<List<Map<String, dynamic>>> fetchConnectionModels(
  Connection c, {
  http.Client? httpClient,
}) async {
  final ids = [
    for (final m in c.config['model_ids'] as List? ?? const []) '$m',
  ];
  if (ids.isNotEmpty) {
    return [
      for (final id in ids) {'id': id, 'name': id, 'owned_by': 'openai'},
    ];
  }
  final client = httpClient ?? http.Client();
  try {
    final res = await client
        .get(Uri.parse('${c.url}/models'), headers: _auth(c))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('It answered ${res.statusCode}');
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    final list = body is Map ? body['data'] : body;
    return [
      for (final m in list is List ? list : const [])
        if (m is Map) m.cast<String, dynamic>(),
    ];
  } finally {
    if (httpClient == null) client.close();
  }
}

/// Null when [c] answers with its models, else what went wrong.
Future<String?> checkConnection(Connection c, {http.Client? httpClient}) async {
  try {
    await fetchConnectionModels(
      Connection(
        url: c.url,
        key: c.key,
        config: {...c.config, 'model_ids': []},
      ),
      httpClient: httpClient,
    );
    return null;
  } catch (e) {
    return "It didn't answer: $e";
  }
}

/// Every model from [list], marked as yours as the web marks them: the
/// connection's index, its prefix and tags, and `direct`.
Future<List<Map<String, dynamic>>> directModels(
  List<Connection> list, {
  http.Client? httpClient,
}) async {
  final found = await Future.wait([
    for (final c in list)
      if (!c.enabled)
        Future.value(const <Map<String, dynamic>>[])
      else
        fetchConnectionModels(
          c,
          httpClient: httpClient,
        ).catchError((_) => const <Map<String, dynamic>>[]),
  ]);
  final out = <Map<String, dynamic>>[];
  for (final (i, models) in found.indexed) {
    final config = list[i].config;
    final prefix = '${config['prefix_id'] ?? ''}';
    final tags = config['tags'] as List? ?? const [];
    for (final m in models) {
      final id = '${m['id']}';
      out.add({
        ...m,
        'id': prefix.isEmpty ? id : '$prefix.$id',
        'name': m['name'] ?? id,
        'openai': {'id': id},
        'urlIdx': '$i',
        if (tags.isNotEmpty) 'tags': tags,
        'direct': true,
      });
    }
  }
  return out;
}

/// The server asked for a reply from one of your connections: send it
/// from the phone and pass every line back on the call's channel, as the
/// web does.
Future<void> runDirectCompletion(
  SocketCall call,
  List<Connection> list,
  void Function(String event, Object? data) emit, {
  http.Client? httpClient,
}) async {
  final channel = '${call.body['channel'] ?? ''}';
  final client = httpClient ?? http.Client();
  try {
    final model = (call.body['model'] as Map?) ?? const {};
    final idx = int.tryParse('${model['urlIdx']}') ?? -1;
    if (idx < 0 || idx >= list.length) {
      throw Exception('That connection is no longer in your settings');
    }
    final c = list[idx];
    final form = Map<String, dynamic>.of(
      ((call.body['form_data'] as Map?) ?? const {}).cast<String, dynamic>(),
    );
    final prefix = '${c.config['prefix_id'] ?? ''}';
    if (prefix.isNotEmpty) {
      form['model'] = '${form['model']}'.replaceFirst('$prefix.', '');
    }
    final req = http.Request('POST', Uri.parse('${c.url}/chat/completions'))
      ..headers.addAll({..._auth(c), 'Content-Type': 'application/json'})
      ..body = jsonEncode(form);
    final res = await client.send(req);
    if (res.statusCode >= 400) {
      final text = await res.stream.bytesToString();
      Object? error;
      try {
        error = jsonDecode(text);
      } catch (_) {
        error = {
          'error': text.isEmpty ? 'It answered ${res.statusCode}' : text,
        };
      }
      call.reply(error);
      return;
    }
    if (form['stream'] == true) {
      call.reply({'status': true});
      await for (final line
          in res.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.trim().isNotEmpty) emit(channel, line);
      }
    } else {
      call.reply(jsonDecode(await res.stream.bytesToString()));
    }
  } catch (e) {
    call.reply({'error': '$e'});
  } finally {
    if (httpClient == null) client.close();
    if (channel.isNotEmpty) emit(channel, {'done': true});
  }
}

class DirectConnectionsScreen extends ConsumerStatefulWidget {
  const DirectConnectionsScreen({super.key});

  @override
  ConsumerState<DirectConnectionsScreen> createState() =>
      _DirectConnectionsScreenState();
}

class _DirectConnectionsScreenState
    extends ConsumerState<DirectConnectionsScreen> {
  List<Connection>? _list;
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    final saved = writeConnections(openAiConnections, true, _list!)
      ..remove(openAiConnections.enableKey);
    try {
      await ref.read(settingsApiProvider).patchUi({
        directConnectionsKey: saved,
      });
      ref
        ..invalidate(userSettingsProvider)
        ..invalidate(uiSettingsProvider)
        ..invalidate(modelsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _edit(Connection? c) async {
    final result = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(
        builder: (_) => ConnectionEditor(
          kind: openAiConnections,
          connection: c,
          verify: checkConnection,
        ),
      ),
    );
    if (result == null || !mounted) return;
    final list = _list!;
    setState(() {
      if (result == 'delete') {
        list.remove(c);
      } else if (c == null && result is Connection) {
        list.add(result);
      }
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(userSettingsProvider).value;
    final config = ref.watch(serverConfigProvider).value;
    final allowed =
        (config?['features'] as Map?)?['enable_direct_connections'] == true;
    if (settings != null && config != null) {
      _list ??= [...directConnectionsOf(settings, config)];
    }
    final list = _list;
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connections'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (allowed && list != null)
            IconButton(
              tooltip: 'Add Connection',
              onPressed: () => _edit(null),
              icon: const Icon(Icons.add),
            ),
        ],
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    allowed
                        ? 'Your own OpenAI-compatible servers. Their models '
                              'show in the model list, and the phone talks to '
                              'them while you chat, so keep the app open '
                              'until a reply finishes.'
                        : 'Your admin has turned off direct connections.',
                    style: TextStyle(color: muted),
                  ),
                ),
                if (allowed && list.isEmpty)
                  const EmptyState(
                    icon: Icons.cable,
                    title: 'No connections yet',
                    message: 'Tap + to add one.',
                  ),
                if (allowed)
                  for (final c in list)
                    ListTile(
                      leading: const Icon(Icons.cable),
                      title: Text(c.url),
                      subtitle: Text(
                        [
                          if ('${c.config['prefix_id'] ?? ''}'.isNotEmpty)
                            'Prefix ${c.config['prefix_id']}',
                          if ((c.config['model_ids'] as List?)?.isNotEmpty ==
                              true)
                            '${(c.config['model_ids'] as List).length} models',
                        ].join(' · ').ifEmpty('All its models'),
                      ),
                      trailing: Switch(
                        value: c.enabled,
                        onChanged: (on) {
                          setState(() => c.config['enable'] = on);
                          _save();
                        },
                      ),
                      onTap: () => _edit(c),
                    ),
              ],
            ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
