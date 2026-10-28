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
  String? get terminalId => meta['terminalId'] as String?;

  static List<String> _strings(Object? v) =>
      (v as List?)?.whereType<String>().toList() ?? const [];
}
