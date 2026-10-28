/// A model's picture, as the web shows it in the model selector: its own
/// (a data URL or a link), else the server's for that model.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/models/model_info.dart';

ImageProvider? modelImage(OpenWebUiClient client, ModelInfo model) {
  final url = model.profileImageUrl ?? '';
  if (url.startsWith('data:image/')) {
    try {
      return MemoryImage(base64Decode(url.substring(url.indexOf(',') + 1)));
    } catch (_) {
      return null;
    }
  }
  if (url.startsWith('http')) return NetworkImage(url);
  return NetworkImage(
    client
        .serverUri(
          '/api/v1/models/model/profile/image?id=${Uri.encodeQueryComponent(model.id)}',
        )
        .toString(),
    headers: client.authHeaders,
  );
}

class ModelAvatar extends ConsumerWidget {
  const ModelAvatar({super.key, required this.model, this.radius = 16});
  final ModelInfo model;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = modelImage(ref.watch(clientProvider), model);
    return CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      foregroundImage: image,
      onForegroundImageError: image == null ? null : (_, _) {},
      child: Icon(Icons.auto_awesome_outlined, size: radius),
    );
  }
}
