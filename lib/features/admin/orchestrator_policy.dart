/// A terminal orchestrator's policy for one connection, as the web's
/// terminal server dialog edits it: the image each person's terminal runs,
/// its limits, storage, idle timeout, environment and lifecycle hooks.
library;

import 'dart:convert';

import '../../core/api/openwebui_client.dart';

class OrchestratorPolicy {
  OrchestratorPolicy({this.id = ''});

  String id;
  String image = '';
  String cpu = '1';
  String memory = '1Gi';
  bool persistent = false;
  String storageSize = '5Gi';
  int idleMinutes = 30;
  String env = '';
  String lifecycle = '{}';

  /// What the orchestrator stores, leaving out what is unset.
  Map<String, dynamic> data() => {
    if (image.trim().isNotEmpty) 'image': image.trim(),
    if (cpu.trim().isNotEmpty) 'cpu_limit': cpu.trim(),
    if (memory.trim().isNotEmpty) 'memory_limit': memory.trim(),
    if (persistent) 'storage': storageSize.trim(),
    if (idleMinutes > 0) 'idle_timeout_minutes': idleMinutes,
    if (parseEnv(env).isNotEmpty) 'env': parseEnv(env),
  };

  void fill(Map? data) {
    data ??= const {};
    image = '${data['image'] ?? ''}';
    cpu = '${data['cpu_limit'] ?? '1'}';
    memory = '${data['memory_limit'] ?? '1Gi'}';
    persistent = data['storage'] != null && '${data['storage']}'.isNotEmpty;
    storageSize = persistent ? '${data['storage']}' : '5Gi';
    idleMinutes = (data['idle_timeout_minutes'] as num?)?.toInt() ?? 30;
    env = [
      for (final e in ((data['env'] as Map?) ?? const {}).entries)
        '${e.key}=${e.value}',
    ].join('\n');
  }

  /// KEY=value lines; lines without a name are left out.
  static Map<String, String> parseEnv(String text) => {
    for (final line in const LineSplitter().convert(text))
      if (line.contains('=') && line.split('=').first.trim().isNotEmpty)
        line.split('=').first.trim(): line.substring(line.indexOf('=') + 1),
  };

  /// The lifecycle JSON as an object; throws [FormatException] otherwise.
  Map<String, dynamic> lifecycleData() {
    final v = jsonDecode(lifecycle.trim().isEmpty ? '{}' : lifecycle);
    if (v is! Map) throw const FormatException('Lifecycle must be an object');
    return v.cast();
  }

  static Map<String, dynamic> _target(Map c) => {
    'url': '${c['url'] ?? ''}'.replaceAll(RegExp(r'/$'), ''),
    'key': c['key'] ?? '',
    'auth_type': c['auth_type'] ?? 'bearer',
  };

  Future<void> load(OpenWebUiClient client, Map connection) async {
    final at = {..._target(connection), 'policy_id': id};
    try {
      final p = await client.send(
        'POST',
        '/api/v1/configs/terminal_servers/policy',
        body: at,
      );
      fill((p as Map?)?['data'] as Map?);
    } on ApiException catch (e) {
      if (e.statusCode != 404) rethrow;
    }
    final l = await client.send(
      'POST',
      '/api/v1/configs/terminal_servers/lifecycle',
      body: at,
    );
    final data = (l as Map?)?['data'];
    lifecycle = const JsonEncoder.withIndent('  ')
        .convert(data is Map && data.isNotEmpty ? data : {});
  }

  Future<void> save(OpenWebUiClient client, Map connection) async {
    final life = lifecycleData();
    final at = {..._target(connection), 'policy_id': id};
    await client.send(
      'POST',
      '/api/v1/configs/terminal_servers/policy',
      body: {...at, 'policy_data': data()},
    );
    await client.send(
      'POST',
      '/api/v1/configs/terminal_servers/lifecycle',
      body: {...at, 'lifecycle_data': life},
    );
  }

  /// Asks the orchestrator to restart this policy's terminals; how many.
  Future<int> refresh(
    OpenWebUiClient client,
    Map connection, {
    required bool onlyIdle,
    required bool reset,
  }) async {
    final res = await client.send(
      'POST',
      '/api/v1/configs/terminal_servers/refresh',
      body: {
        ..._target(connection),
        'policy_id': id,
        'only_idle': onlyIdle,
        'reset': reset,
      },
    );
    return ((res as Map?)?['refreshed'] as num?)?.toInt() ?? 0;
  }
}

/// How an orchestrator splits terminals for chats or automations:
/// 'default' (one per person), a per-item id, or 'off'.
String contextMode(Map? config, String part) {
  final v = (config?['contexts'] as Map?)?[part];
  if (v == false) return 'off';
  if (v is Map && v['context_id'] != null) return '${v['context_id']}';
  return 'default';
}

/// Puts the chat and automation modes into a connection's config.
void setContexts(Map<String, dynamic> config, String chat, String automation) {
  final contexts = <String, dynamic>{
    if (chat == 'off') 'chat': false,
    if (chat == 'chat_id') 'chat': {'context_id': 'chat_id'},
    if (automation == 'off') 'automation': false,
    if (automation == 'automation_id')
      'automation': {'context_id': 'automation_id'},
  };
  if (contexts.isEmpty) {
    config.remove('contexts');
  } else {
    config['contexts'] = contexts;
  }
}
