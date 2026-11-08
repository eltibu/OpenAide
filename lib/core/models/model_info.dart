/// A model as exposed by Open WebUI's `/api/models`.
///
/// The raw JSON is kept so that capabilities added to Open WebUI later
/// (new `info.meta` fields, tool ids, actions) reach the app without a
/// schema change here.
class ModelInfo {
  ModelInfo({required this.id, required this.name, required this.raw});

  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(
    id: json['id'] as String,
    name: (json['name'] as String?)?.trim().isNotEmpty == true
        ? json['name'] as String
        : json['id'] as String,
    raw: json,
  );

  final String id;
  final String name;
  final Map<String, dynamic> raw;

  Map<String, dynamic> get meta =>
      ((raw['info'] as Map?)?['meta'] as Map?)?.cast<String, dynamic>() ??
      const {};

  String? get description => meta['description'] as String?;
  String? get profileImageUrl => meta['profile_image_url'] as String?;
  Map<String, dynamic> get capabilities =>
      (meta['capabilities'] as Map?)?.cast<String, dynamic>() ?? const {};
  List<String> get toolIds => _strings(meta['toolIds']);
  List<String> get defaultFilterIds => _strings(meta['defaultFilterIds']);
  List<String> get filterIds => _strings(meta['filterIds']);
  List<String> get actionIds => _strings(meta['actionIds']);
  List<String> get defaultFeatureIds => _strings(meta['defaultFeatureIds']);
  String? get terminalId =>
      meta['terminalId'] as String? ?? agent?['terminal_id'] as String?;

  /// A coding agent (Claude Code, Codex, Pi...) offered by an Open Terminal
  /// (Open WebUI 0.13.1): `{terminal_id, provider, model}`, or null.
  Map<String, dynamic>? get agent => raw['agent'] is Map
      ? (raw['agent'] as Map).cast<String, dynamic>()
      : null;

  /// Agent chats can't be regenerated, continued, or edited and resent.
  bool get isAgent => agent != null || id.startsWith('agent:');

  static List<String> _strings(Object? v) =>
      (v as List?)?.whereType<String>().toList() ?? const [];
}
