/// Models kept in the sidebar, and the web's model "More" menu: keep in or
/// hide from the sidebar, copy a link, edit.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/models/model_info.dart';
import '../settings/settings_screen.dart'
    show meProvider, settingsApiProvider, uiSettingsProvider;
import '../workspace/models_screen.dart' show ModelEditor, modelsApiProvider;
import 'chat_controller.dart'
    show modelsProvider, serverConfigProvider, userSettingsProvider;

/// Your pinned models, or the server's defaults until you pin your own,
/// as the web reads them.
List<String> pinnedModelIds(Map? ui, Map? config) {
  final own = ui?['pinnedModels'];
  if (own is List) return [for (final v in own) '$v'];
  return [
    for (final id in '${config?['default_pinned_models'] ?? ''}'.split(','))
      if (id.trim().isNotEmpty) id.trim(),
  ];
}

final pinnedModelsProvider = Provider<List<String>>(
  (ref) => pinnedModelIds(
    ref.watch(userSettingsProvider).value?['ui'] as Map?,
    ref.watch(serverConfigProvider).value,
  ),
);

/// Pinned models that are still on the server, in the order pinned.
final visiblePinnedModelsProvider = Provider<List<ModelInfo>>((ref) {
  final models = ref.watch(modelsProvider).value ?? const <ModelInfo>[];
  return [
    for (final id in ref.watch(pinnedModelsProvider))
      ?models.where((m) => m.id == id).firstOrNull,
  ];
});

Future<void> togglePinnedModel(WidgetRef ref, String id) async {
  final pinned = ref.read(pinnedModelsProvider);
  await ref.read(settingsApiProvider).patchUi({
    'pinnedModels': pinned.contains(id)
        ? [
            for (final p in pinned)
              if (p != id) p,
          ]
        : [...pinned, id],
  });
  ref.invalidate(userSettingsProvider);
  ref.invalidate(uiSettingsProvider);
}

List<String> modelTagNames(ModelInfo m) => [
  for (final t in (m.raw['tags'] as List? ?? const []))
    if (t is Map && '${t['name'] ?? ''}'.isNotEmpty) '${t['name']}',
];

/// Every tag on the models, sorted.
List<String> modelTags(List<ModelInfo> models) =>
    {for (final m in models) ...modelTagNames(m)}.toList()..sort();

/// Where a model comes from: local (Ollama), external (OpenAI-style) or
/// direct (your own connection), as the picker's filter.
String modelConnection(ModelInfo m) => m.raw['direct'] == true
    ? 'direct'
    : switch (m.raw['owned_by']) {
        'ollama' => 'local',
        'openai' => 'external',
        _ => '',
      };

/// The web's link that starts a chat with [id].
String modelLink(String serverUrl, String id) {
  final base = serverUrl.endsWith('/') ? serverUrl : '$serverUrl/';
  return '$base?models=${Uri.encodeQueryComponent(id)}';
}

/// Who may edit a model from the picker: its owner for workspace models,
/// admins for the server's own.
bool canEditModel(ModelInfo m, Map? me) {
  final info = m.raw['info'] as Map?;
  final custom = m.raw['preset'] == true || info?['base_model_id'] != null;
  if (custom) return info?['user_id'] == me?['id'];
  return me?['role'] == 'admin';
}

/// The model "More" menu.
class ModelMoreMenu extends ConsumerWidget {
  const ModelMoreMenu({super.key, required this.model, this.icon});
  final ModelInfo model;
  final IconData? icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned = ref.watch(pinnedModelsProvider).contains(model.id);
    final me = ref.watch(meProvider).value;
    final messenger = ScaffoldMessenger.of(context);
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: Icon(icon ?? Icons.more_horiz),
      onSelected: (v) async {
        switch (v) {
          case 'pin':
            try {
              await togglePinnedModel(ref, model.id);
            } catch (e) {
              messenger.showSnackBar(SnackBar(content: Text('$e')));
            }
          case 'link':
            final url = ref.read(sessionProvider).value?.serverUrl ?? '';
            await Clipboard.setData(
              ClipboardData(text: modelLink(url, model.id)),
            );
            messenger.showSnackBar(
              const SnackBar(content: Text('Link copied')),
            );
          case 'edit':
            try {
              final m = await ref.read(modelsApiProvider).get(model.id);
              if (!context.mounted) return;
              final custom = (model.raw['info'] as Map?)?['base_model_id'];
              await Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      ModelEditor(model: m, connectionModel: custom == null),
                ),
              );
              ref.invalidate(modelsProvider);
            } catch (e) {
              messenger.showSnackBar(SnackBar(content: Text('$e')));
            }
        }
      },
      itemBuilder: (_) => [
        if (canEditModel(model, me))
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
        PopupMenuItem(
          value: 'pin',
          child: Text(pinned ? 'Hide from Sidebar' : 'Keep in Sidebar'),
        ),
        const PopupMenuItem(value: 'link', child: Text('Copy Link')),
      ],
    );
  }
}
