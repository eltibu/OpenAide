import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import 'chat_controller.dart';

/// The paperclip: a photo from the gallery or camera, or any file.
class AttachButton extends ConsumerWidget {
  const AttachButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    tooltip: 'Attach',
    icon: const Icon(Icons.attach_file),
    onPressed: () async {
      final choice = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Photos'),
                onTap: () => Navigator.pop(context, 'gallery'),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Camera'),
                onTap: () => Navigator.pop(context, 'camera'),
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: const Text('Files'),
                onTap: () => Navigator.pop(context, 'files'),
              ),
            ],
          ),
        ),
      );
      if (choice == null) return;
      final controller = ref.read(chatControllerProvider.notifier);
      try {
        await _pick(choice, controller);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text("Couldn't attach: $e")));
        }
      }
    },
  );

  Future<void> _pick(String choice, ChatController controller) async {
    // Photos are scaled down like the web UI's compression, so they upload
    // quickly over mobile data and stay within what models accept.
    const maxSide = 2048.0;
    const quality = 85;
    if (choice == 'files') {
      for (final f in await FilePicker.pickFiles()) {
        controller.attach(await f.readAsBytes(), f.name);
      }
      return;
    }
    final picker = ImagePicker();
    final photos = choice == 'camera'
        ? [
            ?await picker.pickImage(
              source: ImageSource.camera,
              maxWidth: maxSide,
              maxHeight: maxSide,
              imageQuality: quality,
            ),
          ]
        : await picker.pickMultiImage(
            maxWidth: maxSide,
            maxHeight: maxSide,
            imageQuality: quality,
          );
    for (final p in photos) {
      controller.attach(
        await p.readAsBytes(),
        p.name,
        mimeType: p.mimeType ?? 'image/jpeg',
      );
    }
  }
}

/// What's waiting to go with the next message, above the text box.
class PendingAttachments extends ConsumerWidget {
  const PendingAttachments({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(
      chatControllerProvider.select((s) => s.attachments),
    );
    if (items.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final controller = ref.read(chatControllerProvider.notifier);
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final a = items[i];
          final tile = a.isImage && a.bytes != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(
                    Uint8List.fromList(a.bytes!),
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                  ),
                )
              : _FileTile(name: a.name, error: a.error != null);
          return Tooltip(
            message: a.error ?? a.warning ?? a.name,
            child: Stack(
              children: [
                tile,
                if (a.uploading)
                  const Positioned.fill(
                    child: Center(
                      child: SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                if (a.error != null)
                  Positioned.fill(
                    child: Icon(Icons.error_outline, color: scheme.error),
                  )
                else if (a.warning != null)
                  Positioned(
                    left: 4,
                    bottom: 4,
                    child: Icon(
                      Icons.warning_amber,
                      size: 18,
                      color: scheme.error,
                    ),
                  ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => controller.removeAttachment(a.key),
                    child: CircleAvatar(
                      radius: 10,
                      backgroundColor: scheme.inverseSurface,
                      child: Icon(
                        Icons.close,
                        size: 14,
                        color: scheme.onInverseSurface,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({required this.name, this.error = false});
  final String name;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 140,
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: error ? scheme.errorContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.description_outlined, size: 20),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Photos and files on a sent message, loaded from the server.
class MessageAttachments extends ConsumerWidget {
  const MessageAttachments({super.key, required this.attachments});
  final List<Attachment> attachments;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final a in attachments)
            if (a.isImage && _image(a, client) != null)
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => _PhotoView(image: _image(a, client)!),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image(
                    image: _image(a, client)!,
                    width: 160,
                    height: 160,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _FileTile(name: a.name),
                  ),
                ),
              )
            else
              _FileTile(name: a.name),
        ],
      ),
    );
  }

  ImageProvider? _image(Attachment a, OpenWebUiClient client) {
    final data = a.dataUrl;
    if (data != null) {
      final comma = data.indexOf(',');
      if (comma < 0) return null;
      return MemoryImage(base64Decode(data.substring(comma + 1)));
    }
    final url = a.url;
    if (url != null && url.startsWith('http')) return NetworkImage(url);
    final id = a.fileId;
    if (id == null) return null;
    return NetworkImage(
      client.fileContentUri(id).toString(),
      headers: client.authHeaders,
    );
  }
}

class _PhotoView extends StatelessWidget {
  const _PhotoView({required this.image});
  final ImageProvider image;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
    ),
    body: Center(
      child: InteractiveViewer(maxScale: 5, child: Image(image: image)),
    ),
  );
}
