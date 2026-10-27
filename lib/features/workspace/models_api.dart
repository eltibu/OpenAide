import '../../core/api/openwebui_client.dart';

/// A model set up in the workspace: a base model with its own name, system
/// prompt, knowledge, tools and abilities. Kept as the server sends it, so
/// settings the app doesn't show are saved back untouched.
class WorkspaceModel {
  WorkspaceModel(this.json);

  final Map<String, dynamic> json;

  String get id => '${json['id']}';
  String get name => '${json['name'] ?? id}';
  String? get baseModelId => json['base_model_id'] as String?;
  bool get active => json['is_active'] != false;
  bool get writable => json['write_access'] != false;

  Map<String, dynamic> get meta =>
      (json['meta'] as Map?)?.cast<String, dynamic>() ?? {};
  Map<String, dynamic> get params =>
      (json['params'] as Map?)?.cast<String, dynamic>() ?? {};

  String get description => '${meta['description'] ?? ''}';
  String get system => '${params['system'] ?? ''}';
  Map<String, dynamic> get capabilities =>
      (meta['capabilities'] as Map?)?.cast<String, dynamic>() ?? {};
  List<String> ids(String key) => [
    for (final v in (meta[key] as List? ?? const [])) '$v',
  ];

  /// Knowledge bases attached: (id, name).
  List<(String, String)> get knowledge => [
    for (final k in (meta['knowledge'] as List? ?? const []).whereType<Map>())
      ('${k['id'] ?? k['collection_name'] ?? ''}', '${k['name'] ?? ''}'),
  ];
}

/// The abilities the web lets a model have, with what they mean.
const modelCapabilities = <String, String>{
  'vision': 'Can look at images',
  'file_upload': 'Accepts files',
  'web_search': 'Can search the web',
  'image_generation': 'Can make images',
  'code_interpreter': 'Can run code',
  'terminal': 'Can use the terminal',
  'citations': 'Shows sources',
  'status_updates': 'Shows what it\'s doing',
  'memory': 'Uses memories',
  'builtin_tools': 'Uses built-in tools',
  'usage': 'Reports token use',
};

class ModelsApi {
  ModelsApi(this.client);
  final OpenWebUiClient client;

  static const _base = '/api/v1/models';

  Future<List<WorkspaceModel>> list() async {
    final out = <WorkspaceModel>[];
    for (var page = 1; page < 20; page++) {
      final res = await client.send(
        'GET',
        '$_base/list',
        query: {'page': '$page'},
      ) as Map;
      final items = (res['items'] as List? ?? const []).whereType<Map>();
      out.addAll(items.map((m) => WorkspaceModel(m.cast<String, dynamic>())));
      if (items.isEmpty || out.length >= ((res['total'] as num?) ?? 0)) break;
    }
    return out;
  }

  Future<WorkspaceModel> get(String id) async => WorkspaceModel(
    ((await client.send('GET', '$_base/model', query: {'id': id})) as Map)
        .cast<String, dynamic>(),
  );

  Future<void> save(Map<String, dynamic> form, {required bool create}) =>
      client.send(
        'POST',
        create ? '$_base/create' : '$_base/model/update',
        body: form,
      );

  Future<void> toggle(String id) =>
      client.send('POST', '$_base/model/toggle', query: {'id': id});

  Future<void> delete(String id) =>
      client.send('POST', '$_base/model/delete', body: {'id': id});
}

/// A model id from its name, as the web makes one.
String modelIdFrom(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), '-')
    .replaceAll(RegExp(r'[^a-z0-9._-]'), '');
