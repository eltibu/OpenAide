/// Open WebUI 0.13.4's image and video models: an admin can add several
/// image connections (and video connections), and you pick which model
/// makes the picture or video from the + menu, as on the web.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/server_version.dart';
import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';
import 'chat_controller.dart';

/// One image or video model you may use: [id] is the server's reference
/// ("connection:model").
class MediaModel {
  const MediaModel({
    required this.id,
    required this.name,
    this.connection = '',
    this.generate = true,
    this.edit = false,
  });

  final String id;
  final String name;
  final String connection;

  /// Images: whether it makes new pictures and edits them.
  final bool generate;
  final bool edit;

  /// "model (connection)", or just the name when they're the same.
  String get label =>
      connection.isEmpty || connection == name ? name : '$name ($connection)';
}

/// `/api/v1/images/models` or `/api/v1/videos/models` (0.13.4) as models.
List<MediaModel> parseMediaModels(Object? json) => [
  for (final m in (json is List ? json : const []).whereType<Map>())
    if ('${m['id'] ?? ''}'.isNotEmpty)
      MediaModel(
        id: '${m['id']}',
        name: '${m['name'] ?? m['model'] ?? m['id']}',
        connection: '${m['connection_name'] ?? ''}',
        generate: m['image_generation'] != false,
        edit: m['image_edit'] == true,
      ),
];

/// The image models ('image_generation') or video models
/// ('video_generation') you may pick from. Empty before Open WebUI 0.13.4,
/// and for video when the admin hasn't given you the permission.
final mediaModelsProvider = FutureProvider.family<List<MediaModel>, String>((
  ref,
  feature,
) async {
  final config = await ref.watch(serverConfigProvider.future);
  if (!isOwui0134(config)) return const [];
  final path = feature == 'video_generation'
      ? '/api/v1/videos/models'
      : '/api/v1/images/models';
  try {
    final res = await ref.watch(clientProvider).send('GET', path);
    final models = parseMediaModels(res);
    // Pictures here mean making new ones.
    return feature == 'image_generation'
        ? [
            for (final m in models)
              if (m.generate) m,
          ]
        : models;
  } catch (_) {
    return const [];
  }
});

/// Whether [feature] can be offered: video needs at least one video model
/// (0.13.4 hands out none without the Video Generation permission).
bool mediaFeatureUsable(String feature, List<MediaModel> videoModels) =>
    feature != 'video_generation' || videoModels.isNotEmpty;

/// A picker for the model [feature] uses in this chat, shown under its
/// switch when there's more than one to choose from.
class MediaModelPicker extends ConsumerWidget {
  const MediaModelPicker({super.key, required this.feature});

  final String feature;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(mediaModelsProvider(feature)).value ?? const [];
    if (models.length < 2) return const SizedBox.shrink();
    final chat = ref.read(chatControllerProvider.notifier);
    final picked = ref.watch(chatControllerProvider).mediaModels[feature] ?? '';
    final value = models.any((m) => m.id == picked) ? picked : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
      child: DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: feature == 'video_generation'
              ? tr('Video model')
              : tr('Image model'),
          isDense: true,
        ),
        items: [
          DropdownMenuItem(value: '', child: T('Default')),
          for (final m in models)
            DropdownMenuItem(
              value: m.id,
              child: Text(m.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => chat.setMediaModel(feature, v ?? ''),
      ),
    );
  }
}
