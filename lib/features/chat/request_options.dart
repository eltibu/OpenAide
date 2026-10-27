import '../../core/models/model_info.dart';

/// What the web UI sends with each message besides the text, so a model gets
/// the same tools, filters, terminal, memory and features as on the web.
///
/// [settings] is `/api/v1/users/user/settings` (null for a new account) and
/// [config] is `/api/config`.
/// Switches the person can flip per chat, as in the web UI's "+" menu.
const featureLabels = {
  'web_search': 'Web search',
  'image_generation': 'Image generation',
  'code_interpreter': 'Code interpreter',
};

const _adminSwitch = {
  'web_search': 'enable_web_search',
  'image_generation': 'enable_image_generation',
  'code_interpreter': 'enable_code_interpreter',
};

/// The features [model] may use on this server: the admin has them on and
/// the model doesn't opt out.
List<String> availableFeatures(ModelInfo? model, Map<String, dynamic>? config) {
  final enabled = (config?['features'] as Map?) ?? const {};
  final caps = model?.capabilities ?? const {};
  return [
    for (final e in _adminSwitch.entries)
      if (enabled[e.value] == true && caps[e.key] != false) e.key,
  ];
}

/// A tool or skill the person can switch on for a chat.
class Pickable {
  const Pickable({required this.id, required this.name, this.description});

  factory Pickable.fromJson(Map<String, dynamic> j) => Pickable(
    id: '${j['id']}',
    name: '${j['name'] ?? j['id']}',
    description:
        (j['description'] ?? (j['meta'] as Map?)?['description']) as String?,
  );

  final String id;
  final String name;
  final String? description;
}

/// [toolIds] and [skillIds] are what the person picked in this chat (null:
/// the model's own tools, no extra skills); [terminalId] is the terminal
/// they picked (null: the model's, '': none). [chatParams] are the chat's
/// own controls.
Map<String, dynamic> requestOptions(
  ModelInfo? model,
  Map<String, dynamic>? settings,
  Map<String, dynamic>? config, {
  Map<String, bool> overrides = const {},
  Set<String>? toolIds,
  Set<String>? skillIds,
  String? terminalId,
  Map<String, dynamic> chatParams = const {},
}) {
  final ui = (settings?['ui'] as Map?) ?? const {};
  final enabled = (config?['features'] as Map?) ?? const {};
  final caps = model?.capabilities ?? const {};

  // A default feature is on when the model has it, it is a default for the
  // model, and the admin has it switched on.
  final features = <String, dynamic>{
    for (final id in model?.defaultFeatureIds ?? const <String>[])
      if (_adminSwitch.containsKey(id) &&
          caps[id] == true &&
          enabled[_adminSwitch[id]] == true)
        id: true,
  };
  final allowed = availableFeatures(model, config);
  // "Always search the web" in Settings > Chats.
  if (ui['webSearch'] == 'always' && allowed.contains('web_search')) {
    features['web_search'] = true;
  }
  // What the person switched in this chat wins over the model's defaults.
  for (final e in overrides.entries) {
    if (e.value && allowed.contains(e.key)) {
      features[e.key] = true;
    } else if (!e.value) {
      features.remove(e.key);
    }
  }
  // Memory follows the person's own setting, else the site's switch.
  final memory = ui['memory'] ?? enabled['enable_memories'] ?? true;
  if (memory == true) features['memory'] = true;

  final tools = toolIds?.toList() ?? model?.toolIds ?? const <String>[];
  final terminal = terminalId ?? model?.terminalId;
  return {
    if (tools.isNotEmpty && enabled['enable_tools'] != false) 'tool_ids': tools,
    if (skillIds != null && skillIds.isNotEmpty) 'skill_ids': skillIds.toList(),
    if (model != null && model.defaultFilterIds.isNotEmpty)
      'filter_ids': model.defaultFilterIds,
    if (terminal != null && terminal.isNotEmpty) 'terminal_id': terminal,
    'features': features,
    // Settings > General's model settings, then this chat's own (Controls).
    if (ui['params'] is Map || chatParams.isNotEmpty)
      'params': {
        ...?(ui['params'] as Map?)?.cast<String, dynamic>(),
        for (final e in chatParams.entries)
          if (e.key != 'system' && e.value != null) e.key: e.value,
      },
    // Naming and tagging new chats follow Settings > Chats, as on the web.
    'background_tasks': {
      'title_generation': (ui['title'] as Map?)?['auto'] != false,
      'tags_generation': ui['autoTags'] != false,
      'follow_up_generation': ui['autoFollowUps'] != false,
    },
  };
}
