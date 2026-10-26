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

Map<String, dynamic> requestOptions(
  ModelInfo? model,
  Map<String, dynamic>? settings,
  Map<String, dynamic>? config, {
  Map<String, bool> overrides = const {},
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
  // What the person switched in this chat wins over the model's defaults.
  final allowed = availableFeatures(model, config);
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

  return {
    if (model != null && model.toolIds.isNotEmpty) 'tool_ids': model.toolIds,
    if (model != null && model.defaultFilterIds.isNotEmpty)
      'filter_ids': model.defaultFilterIds,
    'terminal_id': ?model?.terminalId,
    'features': features,
    if (ui['params'] is Map) 'params': ui['params'],
  };
}
