import '../../core/models/model_info.dart';

/// What the web UI sends with each message besides the text, so a model gets
/// the same tools, filters, terminal, memory and features as on the web.
///
/// [settings] is `/api/v1/users/user/settings` (null for a new account) and
/// [config] is `/api/config`.
Map<String, dynamic> requestOptions(
  ModelInfo? model,
  Map<String, dynamic>? settings,
  Map<String, dynamic>? config,
) {
  final ui = (settings?['ui'] as Map?) ?? const {};
  final enabled = (config?['features'] as Map?) ?? const {};
  final caps = model?.capabilities ?? const {};

  // A default feature is on when the model has it, it is a default for the
  // model, and the admin has it switched on.
  const switches = {
    'web_search': 'enable_web_search',
    'image_generation': 'enable_image_generation',
    'code_interpreter': 'enable_code_interpreter',
  };
  final features = <String, dynamic>{
    for (final id in model?.defaultFeatureIds ?? const <String>[])
      if (switches.containsKey(id) &&
          caps[id] == true &&
          enabled[switches[id]] == true)
        id: true,
  };
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
