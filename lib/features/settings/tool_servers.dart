/// Settings > Integrations, as on the web: your own OpenAPI tool servers,
/// kept with your settings on the server (ui.toolServers). The phone reads
/// each server's spec, offers its tools in a chat's tool picker and sends
/// them with the message; when the model calls one, the server asks the
/// phone to run it, as it asks the browser on the web. Your own terminals
/// (Settings > Terminal connections) go along the same way.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/api/chat_socket.dart';
import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import '../chat/request_options.dart' show Pickable;
import '../terminal/terminal_api.dart';
import 'settings_screen.dart';

const userToolServersKey = 'toolServers';

/// The prefix the web gives your servers' entries in the tool picker.
const directServerPrefix = 'direct_server:';

/// Whether the admin lets people bring their own tool servers.
bool directIntegrationsOn(Map<String, dynamic>? config) {
  final f = (config?['features'] as Map?) ?? const {};
  return f['enable_tool_servers'] == true &&
      f['enable_direct_integrations'] == true;
}

/// Your tool servers, as saved.
List<Map<String, dynamic>> userToolServers(Map? ui) => [
  for (final s
      in (ui?[userToolServersKey] as List? ?? const []).whereType<Map>())
    s.cast<String, dynamic>(),
];

/// The key to send to [server], by its sign-in kind.
String? toolServerToken(Map server, String? sessionToken) =>
    switch ('${server['auth_type'] ?? 'bearer'}') {
      'bearer' => '${server['key'] ?? ''}',
      'session' => sessionToken,
      _ => null,
    };

/// Where [server]'s OpenAPI spec is: its path, joined to its address unless
/// the path is a full address itself.
String specUrl(Map server) {
  final url = '${server['url'] ?? ''}';
  final path = '${server['path'] ?? 'openapi.json'}';
  if (path.contains('://')) return path;
  return '$url${path.startsWith('/') ? '' : '/'}$path';
}

const _httpMethods = {
  'get',
  'put',
  'post',
  'delete',
  'options',
  'head',
  'patch',
  'trace',
};

/// [schema] with its references filled in, as the web resolves them.
Map<String, dynamic> resolveSchema(
  Object? schema,
  Map? components, [
  Set<String>? seen,
]) {
  seen ??= {};
  if (schema is! Map) return {};
  final ref = schema[r'$ref'];
  if (ref is String) {
    final name = ref.split('/').last;
    if (!seen.add(name)) return {};
    return resolveSchema(
      ((components?['schemas'] as Map?) ?? const {})[name],
      components,
      seen,
    );
  }
  List<Map<String, dynamic>>? composed(String key) => schema[key] is List
      ? [
          for (final inner in schema[key] as List)
            resolveSchema(inner, components, seen),
        ]
      : null;
  final type = schema['type'];
  if (type != null) {
    final out = <String, dynamic>{'type': type};
    if (schema['description'] != null) {
      out['description'] = schema['description'];
    }
    if (type == 'object') {
      out['properties'] = {
        for (final e in ((schema['properties'] as Map?) ?? const {}).entries)
          '${e.key}': resolveSchema(e.value, components),
      };
      out['required'] = schema['required'] ?? [];
    } else if (type == 'array') {
      out['items'] = resolveSchema(schema['items'], components);
    }
    for (final k in const ['oneOf', 'anyOf', 'allOf']) {
      final c = composed(k);
      if (c != null) out[k] = c;
    }
    return out;
  }
  final out = <String, dynamic>{};
  for (final k in const ['oneOf', 'anyOf', 'allOf']) {
    final c = composed(k);
    if (c != null) out[k] = c;
  }
  if (out.isNotEmpty && schema['description'] != null) {
    out['description'] = schema['description'];
  }
  return out;
}

Iterable<(String, String, Map, Map)> _operations(Map spec) sync* {
  for (final p in ((spec['paths'] as Map?) ?? const {}).entries) {
    final methods = p.value;
    if (methods is! Map) continue;
    for (final m in methods.entries) {
      if (!_httpMethods.contains(m.key) || m.value is! Map) continue;
      yield ('${p.key}', '${m.key}', methods, m.value as Map);
    }
  }
}

List<Map> _parameters(Map methods, Map operation) {
  final merged = <String, Map>{};
  for (final list in [methods['parameters'], operation['parameters']]) {
    for (final p in (list is List ? list : const []).whereType<Map>()) {
      if (p['name'] != null) merged['${p['name']}:${p['in'] ?? ''}'] = p;
    }
  }
  return merged.values.toList();
}

/// The tools in an OpenAPI [spec], one per operation with an id, as the
/// web describes them to the model.
List<Map<String, dynamic>> openApiTools(Map? spec) {
  if (spec == null || spec['paths'] is! Map) return [];
  final tools = <Map<String, dynamic>>[];
  for (final (_, _, methods, op) in _operations(spec)) {
    final id = op['operationId'];
    if (id == null) continue;
    Map<String, dynamic> parameters = {
      'type': 'object',
      'properties': <String, dynamic>{},
      'required': <dynamic>[],
    };
    for (final p in _parameters(methods, op)) {
      final schema = (p['schema'] as Map?) ?? const {};
      var description = '${schema['description'] ?? p['description'] ?? ''}';
      if (schema['enum'] is List) {
        description +=
            '. Possible values: ${(schema['enum'] as List).join(', ')}';
      }
      parameters['properties'][p['name']] = {
        'type': schema['type'],
        'description': description,
      };
      if (p['required'] == true) parameters['required'].add(p['name']);
    }
    final json =
        ((op['requestBody'] as Map?)?['content'] as Map?)?['application/json'];
    if (json is Map) {
      final body = resolveSchema(json['schema'], spec['components'] as Map?);
      if (body['properties'] is Map) {
        parameters['properties'] = {
          ...parameters['properties'] as Map<String, dynamic>,
          ...body['properties'] as Map<String, dynamic>,
        };
        parameters['required'] = {
          ...parameters['required'] as List,
          ...?body['required'] as List?,
        }.toList();
      } else if (body['type'] == 'array') {
        parameters = body;
      }
    }
    tools.add({
      'name': '$id',
      'description':
          op['description'] ?? op['summary'] ?? 'No description available.',
      'parameters': parameters,
    });
  }
  return tools;
}

/// What a chat sends for [server]: its address, spec, tools and (when it
/// has one) its system prompt. Throws when it can't be read.
Future<Map<String, dynamic>> toolServerData(
  Map server, {
  String? sessionToken,
  http.Client? httpClient,
}) async {
  final token = toolServerToken(server, sessionToken);
  final client = httpClient ?? http.Client();
  final auth = {
    if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
  };
  try {
    Object? spec;
    if ('${server['spec_type'] ?? 'url'}' == 'json') {
      try {
        spec = jsonDecode('${server['spec'] ?? ''}');
      } catch (_) {
        throw Exception('Failed to parse JSON spec');
      }
    } else {
      final res = await client
          .get(Uri.parse(specUrl(server)), headers: auth)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        throw Exception('It answered ${res.statusCode}');
      }
      spec = jsonDecode(utf8.decode(res.bodyBytes));
    }
    if (spec is! Map || spec['paths'] == null) {
      throw Exception('Invalid OpenAPI spec');
    }
    final out = <String, dynamic>{
      'url': server['url'],
      'openapi': spec,
      'info': spec['info'],
      'specs': openApiTools(spec),
    };
    // A server that has its own instructions for the model shares them.
    try {
      final base = '${server['url']}'.replaceAll(RegExp(r'/$'), '');
      final config = await client
          .get(Uri.parse('$base/api/config'))
          .timeout(const Duration(seconds: 10));
      if (config.statusCode == 200 &&
          ((jsonDecode(config.body) as Map?)?['features'] as Map?)?['system'] !=
              null) {
        final system = await client
            .get(Uri.parse('$base/system'), headers: auth)
            .timeout(const Duration(seconds: 10));
        final answer = system.statusCode == 200
            ? jsonDecode(system.body)
            : null;
        final prompt = answer is Map ? answer['prompt'] : null;
        if (prompt != null) out['system_prompt'] = prompt;
      }
    } catch (_) {
      // No /system: that's fine.
    }
    return out;
  } finally {
    if (httpClient == null) client.close();
  }
}

/// Your terminals, described as tool servers for a chat.
List<Map<String, dynamic>> _terminalsAsServers(Map? ui) => [
  for (final s in userTerminalConfigs(ui))
    if (s['enabled'] != false)
      {
        'url': s['url'],
        'auth_type': s['auth_type'] ?? 'bearer',
        'key': s['key'] ?? '',
        'path': s['path'] ?? '/openapi.json',
        'config': {'enable': true},
      },
];

Future<List<Map<String, dynamic>>> _read(
  List<Map<String, dynamic>> servers,
  String? token,
) async {
  final read = await Future.wait([
    for (final s in servers)
      toolServerData(
        s,
        sessionToken: token,
      ).then<Map<String, dynamic>?>((d) => d, onError: (_) => null),
  ]);
  return [
    for (final (i, d) in read.indexed)
      if (d != null) {...d, 'key': servers[i]['key'] ?? ''},
  ];
}

/// Your switched-on tool servers that answered, in order: the picker's
/// `direct_server:<index>` counts in this list, as on the web.
final userToolServersDataProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final config = await ref.watch(serverConfigProvider.future);
  if (!directIntegrationsOn(config)) return const [];
  final saved = await ref.watch(
    userSettingsProvider.selectAsync(
      (s) => jsonEncode((s['ui'] as Map?)?[userToolServersKey]),
    ),
  );
  final servers = [
    for (final s in userToolServers({userToolServersKey: jsonDecode(saved)}))
      if ((s['config'] as Map?)?['enable'] == true) s,
  ];
  final token = ref.watch(sessionProvider).value?.token;
  return _read(servers, token);
});

/// Your switched-on terminals that answered, as tool servers.
final userTerminalsDataProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final config = await ref.watch(serverConfigProvider.future);
  if (!directIntegrationsOn(config)) return const [];
  final saved = await ref.watch(
    userSettingsProvider.selectAsync(
      (s) => jsonEncode((s['ui'] as Map?)?[userTerminalsKey]),
    ),
  );
  return _read(
    _terminalsAsServers({userTerminalsKey: jsonDecode(saved)}),
    null,
  );
});

/// The tools and skills a chat's picker offers, with your tool servers.
final chatToolsProvider = FutureProvider<List<Pickable>>((ref) async {
  final tools = await ref.watch(toolsProvider.future);
  List<Map<String, dynamic>> mine;
  try {
    mine = await ref.watch(userToolServersDataProvider.future);
  } catch (_) {
    mine = const [];
  }
  return [
    ...tools,
    for (final (i, s) in mine.indexed)
      if (s['info'] is Map)
        Pickable(
          id: '$directServerPrefix$i',
          name: '${(s['info'] as Map)['title'] ?? s['url']}',
          description: (s['info'] as Map)['description'] as String?,
        ),
  ];
});

/// What goes as tool_servers with a message: the servers picked from
/// [toolIds], and your terminals when the model may use a terminal.
List<Map<String, dynamic>> chatToolServers(
  Set<String> toolIds,
  List<Map<String, dynamic>> servers,
  List<Map<String, dynamic>> terminals, {
  bool terminal = true,
}) => [
  for (final (i, s) in servers.indexed)
    if (toolIds.contains('$directServerPrefix$i')) s,
  if (terminal)
    for (final t in terminals) {...t, 'is_terminal': true},
];

/// Calls [name] (an operation id) on a tool server, as the web does: path
/// and query parameters from [params], the rest as the JSON body. Returns
/// [result, headers], or [{error}, null].
Future<List<Object?>> runToolServer(
  String? token,
  String url,
  String name,
  Map<String, dynamic> params,
  Map spec, {
  String? sessionId,
  http.Client? httpClient,
}) async {
  final client = httpClient ?? http.Client();
  try {
    final found = _operations(spec)
        .where((o) => o.$4['operationId'] == name)
        .firstOrNull;
    if (found == null) {
      throw Exception('No matching route found for operationId: $name');
    }
    final (route, method, methods, op) = found;
    final declared = <String>{};
    final query = <String, String>{};
    var path = route;
    for (final p in _parameters(methods, op)) {
      final n = '${p['name']}';
      declared.add(n);
      if (!params.containsKey(n)) continue;
      if (p['in'] == 'path') {
        path = path.replaceAll('{$n}', Uri.encodeComponent('${params[n]}'));
      } else if (p['in'] == 'query') {
        query[n] = '${params[n]}';
      }
    }
    Object? body;
    final content = (op['requestBody'] as Map?)?['content'];
    if (content is Map) {
      final schema = resolveSchema(
        (content['application/json'] as Map?)?['schema'],
        spec['components'] as Map?,
      );
      final composed = ['allOf', 'anyOf', 'oneOf'].any(schema.containsKey);
      final props = composed
          ? const {}
          : (schema['properties'] as Map?) ?? const {};
      body = props.isEmpty
          ? params
          : {
              for (final e in params.entries)
                if (props.containsKey(e.key) || !declared.contains(e.key))
                  e.key: e.value,
            };
    }
    var uri = Uri.parse('$url$path');
    if (query.isNotEmpty) {
      uri = uri.replace(queryParameters: {...uri.queryParameters, ...query});
    }
    final req = http.Request(method.toUpperCase(), uri)
      ..headers.addAll({
        'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty) 'authorization': 'Bearer $token',
        'X-Session-Id': ?sessionId,
      });
    if (body != null && {'post', 'put', 'patch', 'delete'}.contains(method)) {
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await client.send(req));
    if (res.statusCode >= 400) {
      throw Exception(
        'HTTP error! Status: ${res.statusCode}. Message: ${res.body}',
      );
    }
    final type = (res.headers['content-type'] ?? '').split(';').first.trim();
    Object? data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      data = type.isEmpty || type.startsWith('text/')
          ? utf8.decode(res.bodyBytes, allowMalformed: true)
          : 'data:$type;base64,${base64Encode(res.bodyBytes)}';
    }
    return [data, res.headers];
  } catch (e) {
    return [
      {'error': '$e'.replaceFirst('Exception: ', '')},
      null,
    ];
  } finally {
    if (httpClient == null) client.close();
  }
}

/// The server asks the phone to run one of your tools.
Future<void> answerExecuteTool(
  SocketCall call, {
  required Map? ui,
  required String? sessionToken,
  required List<Map<String, dynamic>> data,
  http.Client? httpClient,
}) async {
  final url = '${(call.body['server'] as Map?)?['url'] ?? ''}';
  Map? server = userToolServers(ui).where((s) => s['url'] == url).firstOrNull;
  server ??= _terminalsAsServers(ui).where((s) => s['url'] == url).firstOrNull;
  final spec = data.where((d) => d['url'] == url).firstOrNull?['openapi'];
  if (server == null || spec is! Map) {
    call.reply({'error': 'Tool Server Not Found'});
    return;
  }
  call.reply(
    await runToolServer(
      toolServerToken(server, sessionToken),
      url,
      '${call.body['name']}',
      ((call.body['params'] as Map?) ?? const {}).cast<String, dynamic>(),
      spec,
      sessionId: call.chatId,
      httpClient: httpClient,
    ),
  );
}

/// The server reads from one of your terminals through the phone (its
/// AGENTS.md, for instance).
Future<void> answerTerminalRequest(
  SocketCall call, {
  required Map? ui,
  required String serverUrl,
  required String? sessionToken,
  required bool systemTerminal,
  http.Client? httpClient,
}) async {
  final id = '${call.body['terminal_id'] ?? ''}';
  final path = '${call.body['path'] ?? ''}';
  String? base;
  String key = '';
  if (systemTerminal) {
    base = '$serverUrl/api/v1/terminals/${Uri.encodeComponent(id)}';
    key = sessionToken ?? '';
  } else {
    final mine = userTerminalConfigs(ui)
        .where((s) => s['url'] == id)
        .firstOrNull;
    if (mine != null) {
      base = '${mine['url']}'.replaceAll(RegExp(r'/$'), '');
      key = '${mine['key'] ?? ''}'.trim();
    }
  }
  if (base == null) {
    call.reply({'error': 'Terminal Not Found'});
    return;
  }
  final client = httpClient ?? http.Client();
  try {
    final res = await client.get(
      Uri.parse('$base$path'),
      headers: {'Authorization': 'Bearer $key', 'X-Session-Id': ?call.chatId},
    );
    if (res.statusCode >= 400) {
      throw Exception('Terminal request failed (${res.statusCode})');
    }
    call.reply({'data': jsonDecode(utf8.decode(res.bodyBytes))});
  } catch (e) {
    call.reply({'error': '$e'});
  } finally {
    if (httpClient == null) client.close();
  }
}

class ToolServersScreen extends ConsumerStatefulWidget {
  const ToolServersScreen({super.key});

  @override
  ConsumerState<ToolServersScreen> createState() => _ToolServersScreenState();
}

class _ToolServersScreenState extends ConsumerState<ToolServersScreen> {
  List<Map<String, dynamic>>? _list;
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(settingsApiProvider).patchUi({userToolServersKey: _list});
      ref
        ..invalidate(userSettingsProvider)
        ..invalidate(uiSettingsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _edit(int? index) async {
    final result = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ToolServerEditor(server: index == null ? null : _list![index]),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (result == 'delete') {
        _list!.removeAt(index!);
      } else if (result is Map<String, dynamic>) {
        if (index == null) {
          _list!.add(result);
        } else {
          _list![index] = result;
        }
      }
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(userSettingsProvider).value;
    final config = ref.watch(serverConfigProvider).value;
    final allowed = directIntegrationsOn(config);
    if (settings != null) {
      _list ??= [
        for (final s in userToolServers(settings['ui'] as Map?))
          (jsonDecode(jsonEncode(s)) as Map).cast<String, dynamic>(),
      ];
    }
    final list = _list;
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Integrations'),
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
      body: list == null || config == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    allowed
                        ? 'Your own OpenAPI tool servers. Switch one on in a '
                              "chat's tools; the phone runs its tools while "
                              'you chat, so keep the app open until a reply '
                              'finishes.'
                        : 'Your admin has turned off your own tool servers.',
                    style: TextStyle(color: muted),
                  ),
                ),
                if (allowed && list.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.extension_outlined),
                    title: Text('No tool servers yet'),
                    subtitle: Text('Add one with +'),
                  ),
                if (allowed)
                  for (final (i, s) in list.indexed)
                    ListTile(
                      leading: const Icon(Icons.extension_outlined),
                      title: Text(
                        '${(s['info'] as Map?)?['name'] ?? ''}'.isEmpty
                            ? '${s['url']}'
                            : '${(s['info'] as Map)['name']}',
                      ),
                      subtitle: Text(specUrl(s)),
                      trailing: Switch(
                        value: (s['config'] as Map?)?['enable'] == true,
                        onChanged: (on) {
                          setState(
                            () => s['config'] = {
                              ...?(s['config'] as Map?),
                              'enable': on,
                            },
                          );
                          _save();
                        },
                      ),
                      onTap: () => _edit(i),
                    ),
              ],
            ),
    );
  }
}

/// Add or edit one of your tool servers, as the web's direct form.
class ToolServerEditor extends ConsumerStatefulWidget {
  const ToolServerEditor({super.key, this.server});
  final Map<String, dynamic>? server;

  @override
  ConsumerState<ToolServerEditor> createState() => _ToolServerEditorState();
}

class _ToolServerEditorState extends ConsumerState<ToolServerEditor> {
  late final Map<String, dynamic> _s = {
    'type': 'openapi',
    'url': '',
    'spec_type': 'url',
    'spec': '',
    'path': 'openapi.json',
    'auth_type': 'bearer',
    'key': '',
    'config': {'enable': true},
    'info': {'id': '', 'name': '', 'description': ''},
    ...?widget.server,
  };
  late final _url = TextEditingController(text: '${_s['url']}');
  late final _path = TextEditingController(text: '${_s['path'] ?? ''}');
  late final _spec = TextEditingController(text: '${_s['spec'] ?? ''}');
  late final _key = TextEditingController(text: '${_s['key'] ?? ''}');
  late final _name = TextEditingController(
    text: '${(_s['info'] as Map?)?['name'] ?? ''}',
  );
  late final _description = TextEditingController(
    text: '${(_s['info'] as Map?)?['description'] ?? ''}',
  );
  late String _specType = '${_s['spec_type'] ?? 'url'}';
  late String _auth = '${_s['auth_type'] ?? 'bearer'}';
  late bool _enabled = (_s['config'] as Map?)?['enable'] == true;
  bool _hidden = true;
  bool _checking = false;

  @override
  void dispose() {
    for (final c in [_url, _path, _spec, _key, _name, _description]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _result() => {
    ..._s,
    'url': _url.text.trim().replaceAll(RegExp(r'/+$'), ''),
    'spec_type': _specType,
    'spec': _spec.text,
    'path': _path.text.trim(),
    'auth_type': _auth,
    'key': _key.text.trim(),
    'config': {...?(_s['config'] as Map?), 'enable': _enabled},
    'info': {
      ...?(_s['info'] as Map?),
      'name': _name.text.trim(),
      'description': _description.text.trim(),
    },
  };

  Future<void> _verify() async {
    setState(() => _checking = true);
    String text;
    try {
      final d = await toolServerData(
        _result(),
        sessionToken: ref.read(sessionProvider).value?.token,
      );
      text = 'Connection successful: ${(d['specs'] as List).length} tools';
    } catch (e) {
      text = 'Connection failed: $e';
    }
    if (!mounted) return;
    setState(() => _checking = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.server == null ? 'Add Connection' : 'Edit Connection',
        ),
        actions: [
          if (widget.server != null)
            IconButton(
              tooltip: 'Delete',
              onPressed: () => Navigator.pop(context, 'delete'),
              icon: const Icon(Icons.delete_outline),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: () {
                if (_url.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Enter the URL')),
                  );
                  return;
                }
                Navigator.pop(context, _result());
              },
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'URL'),
          ),
          DropdownButtonFormField<String>(
            initialValue: _specType,
            decoration: const InputDecoration(labelText: 'OpenAPI spec'),
            items: const [
              DropdownMenuItem(value: 'url', child: Text('From a URL path')),
              DropdownMenuItem(value: 'json', child: Text('Paste JSON')),
            ],
            onChanged: (v) => setState(() => _specType = v ?? 'url'),
          ),
          if (_specType == 'url')
            TextField(
              controller: _path,
              decoration: const InputDecoration(
                labelText: 'Path',
                helperText: 'openapi.json, or a full address',
              ),
            )
          else
            TextField(
              controller: _spec,
              minLines: 3,
              maxLines: 10,
              decoration: const InputDecoration(labelText: 'JSON spec'),
            ),
          DropdownButtonFormField<String>(
            initialValue: _auth,
            decoration: const InputDecoration(labelText: 'Auth'),
            items: const [
              DropdownMenuItem(value: 'bearer', child: Text('Bearer key')),
              DropdownMenuItem(value: 'session', child: Text('Your session')),
              DropdownMenuItem(value: 'none', child: Text('None')),
            ],
            onChanged: (v) => setState(() => _auth = v ?? 'bearer'),
          ),
          if (_auth == 'bearer')
            TextField(
              controller: _key,
              obscureText: _hidden,
              decoration: InputDecoration(
                labelText: 'Key',
                suffixIcon: IconButton(
                  tooltip: _hidden ? 'Show' : 'Hide',
                  onPressed: () => setState(() => _hidden = !_hidden),
                  icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
                ),
              ),
            ),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          TextField(
            controller: _description,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            value: _enabled,
            onChanged: (on) => setState(() => _enabled = on),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _checking ? null : _verify,
            icon: _checking
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_tethering),
            label: const Text('Verify connection'),
          ),
        ],
      ),
    );
  }
}
