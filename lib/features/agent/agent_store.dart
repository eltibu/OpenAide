/// What the agent has on this phone (Tools and skills): which built-in
/// tools and skills are on, your own skills, MCP servers and tool servers,
/// the search engine, and what it remembers and notes. Kept in a file in
/// the app's folder; keys and sign-ins go in the phone's keystore.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/agent/skills.dart';
import '../../core/agent/web_tools.dart';

const _storage = FlutterSecureStorage();
const _kSecrets = 'agent_secrets';
const _uuid = Uuid();

String newAgentId() => _uuid.v4().substring(0, 8);

/// Everything in Tools and skills. [data] is saved as a file, [secrets] in
/// the keystore.
class AgentConfig {
  const AgentConfig(this.data, this.secrets);
  final Map<String, dynamic> data;
  final Map<String, dynamic> secrets;

  List<Map<String, dynamic>> _list(String key) => [
    for (final m in (data[key] as List? ?? const []).whereType<Map>())
      m.cast<String, dynamic>(),
  ];

  Set<String> _set(String key) => {
    for (final v in (data[key] as List? ?? const [])) '$v',
  };

  /// Built-in tools you switched off, by name.
  Set<String> get offTools => _set('off_tools');

  /// Skills you switched off, by id.
  Set<String> get offSkills => _set('off_skills');

  /// Skills you added.
  List<Skill> get mySkills => [
    for (final s in _list('skills')) Skill.fromJson(s),
  ];

  /// Built-in skills, then yours (yours win on the same id).
  List<Skill> get allSkills {
    final mine = mySkills;
    final ids = {for (final s in mine) s.id};
    return [
      for (final s in builtInSkills)
        if (!ids.contains(s.id)) s,
      ...mine,
    ];
  }

  List<Skill> get onSkills => [
    for (final s in allSkills)
      if (!offSkills.contains(s.id)) s,
  ];

  /// MCP servers: id, name, url, auth (none, key or oauth), headers,
  /// enabled, client_id.
  List<Map<String, dynamic>> get mcpServers => _list('mcp');

  /// OpenAPI tool servers, in the same shape as Open WebUI's (url, path,
  /// auth_type, config.enable) plus an id and name.
  List<Map<String, dynamic>> get toolServers => _list('tool_servers');

  SearchEngine get searchEngine =>
      SearchEngine.byId((data['search'] as Map?)?['engine'] as String?);
  String? get searchUrl => (data['search'] as Map?)?['url'] as String?;
  String? get searchKey => secrets['search_key'] as String?;

  /// Facts the model was asked to remember: id, text, at (ms).
  List<Map<String, dynamic>> get memories => _list('memory');

  /// Notes saved on the phone: id, title, content, at (ms).
  List<Map<String, dynamic>> get notes => _list('notes');

  /// Whether the agent remembers things you tell it.
  bool get memoryOn => data['memory_on'] != false;

  Map<String, dynamic> secretFor(String id) =>
      (secrets['srv_$id'] as Map?)?.cast<String, dynamic>() ?? {};
}

class AgentStore extends AsyncNotifier<AgentConfig> {
  File? _file;

  @override
  Future<AgentConfig> build() async {
    Map<String, dynamic> data = {};
    Map<String, dynamic> secrets = {};
    try {
      final support = await getApplicationSupportDirectory();
      final f = _file = File('${support.path}/agent.json');
      if (await f.exists()) {
        data = (jsonDecode(await f.readAsString()) as Map)
            .cast<String, dynamic>();
      }
    } catch (_) {
      // A damaged file: start empty rather than failing every chat.
    }
    try {
      final s = await _storage.read(key: _kSecrets);
      if (s != null) secrets = (jsonDecode(s) as Map).cast<String, dynamic>();
    } catch (_) {}
    return AgentConfig(data, secrets);
  }

  /// The settings now, once loaded.
  Future<AgentConfig> current() async => state.value ?? await future;

  /// Changes the saved settings with [change] and saves them.
  /// One change at a time, so two quick edits can't both start from the
  /// same settings or write the same .tmp file at once.
  Future<void> _queue = Future.value();

  Future<void> _inTurn(Future<void> Function() step) {
    final next = _queue.then((_) => step());
    _queue = next.catchError((_) {});
    return next;
  }

  Future<void> edit(void Function(Map<String, dynamic> data) change) =>
      _inTurn(() => _edit(change));

  Future<void> _edit(void Function(Map<String, dynamic> data) change) async {
    final now = await current();
    final data = jsonDecode(jsonEncode(now.data)) as Map<String, dynamic>;
    change(data);
    final f = _file;
    if (f != null) {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(data));
      await tmp.rename(f.path);
    }
    state = AsyncData(AgentConfig(data, now.secrets));
  }

  /// Changes the keystore part with [change] and saves it.
  Future<void> editSecrets(
    void Function(Map<String, dynamic> secrets) change,
  ) => _inTurn(() => _editSecrets(change));

  Future<void> _editSecrets(
    void Function(Map<String, dynamic> secrets) change,
  ) async {
    final now = await current();
    final secrets = jsonDecode(jsonEncode(now.secrets)) as Map<String, dynamic>;
    change(secrets);
    try {
      await _storage.write(key: _kSecrets, value: jsonEncode(secrets));
    } catch (_) {}
    state = AsyncData(AgentConfig(now.data, secrets));
  }

  Future<void> setSecretFor(String id, Map<String, dynamic>? value) =>
      editSecrets((s) {
        if (value == null || value.isEmpty) {
          s.remove('srv_$id');
        } else {
          s['srv_$id'] = value;
        }
      });

  Future<void> _toggle(String key, String id, bool on) => edit((d) {
    final set = {for (final v in (d[key] as List? ?? const [])) '$v'};
    on ? set.remove(id) : set.add(id);
    d[key] = set.toList();
  });

  Future<void> setToolOn(String name, bool on) =>
      _toggle('off_tools', name, on);

  Future<void> setSkillOn(String id, bool on) => _toggle('off_skills', id, on);

  Future<void> saveSkill(Skill skill, {String? replacing}) => edit((d) {
    final list = [
      for (final s in (d['skills'] as List? ?? const []).whereType<Map>())
        if (s['id'] != skill.id && s['id'] != replacing) s,
    ];
    d['skills'] = [...list, skill.toJson()];
  });

  Future<void> deleteSkill(String id) => edit((d) {
    d['skills'] = [
      for (final s in (d['skills'] as List? ?? const []).whereType<Map>())
        if (s['id'] != id) s,
    ];
  });

  Future<void> _saveIn(String key, Map<String, dynamic> item) => edit((d) {
    final list = [
      for (final s in (d[key] as List? ?? const []).whereType<Map>()) s,
    ];
    final i = list.indexWhere((s) => s['id'] == item['id']);
    if (i < 0) {
      list.add(item);
    } else {
      list[i] = item;
    }
    d[key] = list;
  });

  Future<void> _deleteIn(String key, String id) => edit((d) {
    d[key] = [
      for (final s in (d[key] as List? ?? const []).whereType<Map>())
        if (s['id'] != id) s,
    ];
  });

  Future<void> saveMcpServer(Map<String, dynamic> server) =>
      _saveIn('mcp', server);

  Future<void> deleteMcpServer(String id) async {
    await _deleteIn('mcp', id);
    await setSecretFor(id, null);
  }

  Future<void> saveToolServer(Map<String, dynamic> server) =>
      _saveIn('tool_servers', server);

  Future<void> deleteToolServer(String id) async {
    await _deleteIn('tool_servers', id);
    await setSecretFor(id, null);
  }

  Future<void> setSearch(
    SearchEngine engine, {
    String? url,
    String? key,
  }) async {
    await edit((d) => d['search'] = {'engine': engine.id, 'url': ?url});
    await editSecrets((s) {
      if (key == null || key.trim().isEmpty) {
        s.remove('search_key');
      } else {
        s['search_key'] = key.trim();
      }
    });
  }

  Future<void> setMemoryOn(bool on) => edit((d) => d['memory_on'] = on);

  Future<String> remember(String text) async {
    final id = newAgentId();
    await _saveIn('memory', {
      'id': id,
      'text': text.trim(),
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    return id;
  }

  Future<void> forget(String id) => _deleteIn('memory', id);

  Future<void> clearMemory() => edit((d) => d['memory'] = []);

  Future<Map<String, dynamic>> saveNote({
    String? id,
    required String title,
    required String content,
  }) async {
    final note = {
      'id': id ?? newAgentId(),
      'title': title.trim().isEmpty ? 'Note' : title.trim(),
      'content': content,
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    await _saveIn('notes', note);
    return note;
  }

  Future<void> deleteNote(String id) => _deleteIn('notes', id);
}

final agentStoreProvider = AsyncNotifierProvider<AgentStore, AgentConfig>(
  AgentStore.new,
);
