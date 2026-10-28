import 'dart:math' as math;
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import 'attach_more.dart';
import 'chat_controller.dart';
import 'side_panel.dart';
import 'voice_note.dart';

/// The paperclip: photos and videos from the gallery or camera, or any file.
class AttachButton extends ConsumerWidget {
  const AttachButton({super.key, this.onCompare});

  /// Opens Compare text with the message box's text.
  final VoidCallback? onCompare;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton.outlined(
    tooltip: 'Add photos and files',
    visualDensity: VisualDensity.compact,
    style: IconButton.styleFrom(
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    icon: const Icon(Icons.add),
    onPressed: () async {
      final choice = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Photos and videos'),
                  onTap: () => Navigator.pop(context, 'gallery'),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Take a photo'),
                  onTap: () => Navigator.pop(context, 'camera'),
                ),
                ListTile(
                  leading: const Icon(Icons.videocam_outlined),
                  title: const Text('Record a video'),
                  onTap: () => Navigator.pop(context, 'video'),
                ),
                ListTile(
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: const Text('Files'),
                  onTap: () => Navigator.pop(context, 'files'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.public),
                  title: const Text('Web page'),
                  onTap: () => Navigator.pop(context, 'web'),
                ),
                ListTile(
                  leading: const Icon(Icons.sticky_note_2_outlined),
                  title: const Text('Note'),
                  onTap: () => Navigator.pop(context, 'note'),
                ),
                ListTile(
                  leading: const Icon(Icons.menu_book_outlined),
                  title: const Text('Knowledge'),
                  onTap: () => Navigator.pop(context, 'collection'),
                ),
                ListTile(
                  leading: const Icon(Icons.forum_outlined),
                  title: const Text('Past chat'),
                  onTap: () => Navigator.pop(context, 'chat'),
                ),
                if (onCompare != null) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.difference_outlined),
                    title: const Text('Compare text'),
                    onTap: () => Navigator.pop(context, 'compare'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
      if (choice == null || !context.mounted) return;
      if (choice == 'compare') return onCompare?.call();
      if (choice == 'web') return attachWebpage(context, ref);
      if (const {'note', 'collection', 'chat'}.contains(choice)) {
        return attachFromServer(context, ref, choice);
      }
      final controller = ref.read(chatControllerProvider.notifier);
      try {
        await _pick(
          choice,
          controller,
          ref.read(userSettingsProvider).value?['ui'] as Map?,
        );
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text("Couldn't attach: $e")));
        }
      }
    },
  );

  Future<void> _pick(String choice, ChatController controller, Map? ui) async {
    // Photos are scaled down like the web UI's compression, so they upload
    // quickly over mobile data and stay within what models accept.
    final (maxW, maxH) = imageLimits(ui);
    const quality = 85;
    if (choice == 'files') {
      for (final f in await FilePicker.pickFiles()) {
        controller.attach(await f.readAsBytes(), f.name);
      }
      return;
    }
    final picker = ImagePicker();
    final picked = switch (choice) {
      'camera' => [
        ?await picker.pickImage(
          source: ImageSource.camera,
          maxWidth: maxW,
          maxHeight: maxH,
          imageQuality: quality,
        ),
      ],
      'video' => [?await picker.pickVideo(source: ImageSource.camera)],
      // Size limits only touch the photos; videos come as they are.
      _ => await picker.pickMultipleMedia(
        maxWidth: maxW,
        maxHeight: maxH,
        imageQuality: quality,
      ),
    };
    for (final p in picked) {
      final video = choice == 'video' || isVideoName(p.name);
      controller.attach(
        await p.readAsBytes(),
        p.name,
        mimeType: p.mimeType ?? (video ? _videoType(p.name) : 'image/jpeg'),
      );
    }
  }

  static String _videoType(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      '3gp' => 'video/3gpp',
      'mkv' => 'video/x-matroska',
      _ => 'video/mp4',
    };
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
              : _FileTile(
                  name: a.name,
                  error: a.error != null,
                  type: a.uploaded?.type,
                );
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

/// Whether a file name looks like a video.
bool isVideoName(String name) => RegExp(
  r'\.(mp4|m4v|mov|webm|mkv|3gp)$',
  caseSensitive: false,
).hasMatch(name);

class _FileTile extends StatelessWidget {
  const _FileTile({required this.name, this.error = false, this.type});
  final String name;
  final bool error;

  /// `note`, `collection`, `chat` or `text` (a web page) for things that
  /// aren't files.
  final String? type;

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
          Icon(
            switch (type) {
                  'note' => Icons.sticky_note_2_outlined,
                  'collection' => Icons.menu_book_outlined,
                  'chat' => Icons.forum_outlined,
                  'text' => Icons.public,
                  _ => null,
                } ??
                (isVideoName(name)
                    ? Icons.movie_outlined
                    : name.toLowerCase().endsWith('.wav')
                    ? Icons.mic_none
                    : Icons.description_outlined),
            size: 20,
          ),
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

/// Photos, videos and files on a message, loaded from the server: what the
/// person sent, or what a reply made (generated pictures).
class MessageAttachments extends ConsumerWidget {
  const MessageAttachments({
    super.key,
    required this.attachments,
    this.alignEnd = true,
  });
  final List<Attachment> attachments;
  final bool alignEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    final single = attachments.length == 1;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final a in attachments)
            if (a.isImage && attachmentImage(a, client) != null)
              _Thumb(
                image: attachmentImage(a, client)!,
                name: a.name,
                // A lone generated picture shows large, as on the web.
                size: !alignEnd && single ? 280 : 160,
              )
            else if (a.isAudio && attachmentUri(a, client) != null)
              AudioTile(
                uri: attachmentUri(a, client)!,
                headers: client.authHeaders,
                name: a.name,
              )
            else if (a.isVideo && attachmentUri(a, client) != null)
              _VideoTile(
                uri: attachmentUri(a, client)!,
                headers: client.authHeaders,
                name: a.name,
              )
            else
              _FileTile(name: a.name, type: a.type),
        ],
      ),
    );
  }
}

/// Where an attachment's bytes are on the server, if they are.
Uri? attachmentUri(Attachment a, OpenWebUiClient client) {
  final url = a.url;
  if (url != null && url.startsWith('http')) return Uri.parse(url);
  final id = a.fileId;
  if (id != null) return client.fileContentUri(id);
  final path = a.serverPath;
  if (path != null) return client.serverUri(path);
  return null;
}

ImageProvider? attachmentImage(Attachment a, OpenWebUiClient client) {
  final data = a.dataUrl;
  if (data != null) return dataUrlImage(data);
  final url = a.url;
  if (url != null && url.startsWith('http')) return NetworkImage(url);
  final uri = attachmentUri(a, client);
  if (uri == null) return null;
  return NetworkImage(uri.toString(), headers: client.authHeaders);
}

ImageProvider? dataUrlImage(String data) {
  final comma = data.indexOf(',');
  if (comma < 0) return null;
  try {
    return MemoryImage(base64Decode(data.substring(comma + 1)));
  } catch (_) {
    return null;
  }
}

/// An image a reply writes in Markdown: a data URL, a full address, or a
/// path on the server (fetched signed in).
ImageProvider? markdownImage(String url, OpenWebUiClient client) {
  if (url.startsWith('data:')) return dataUrlImage(url);
  if (url.startsWith('http')) {
    final own = Uri.parse(url).host == Uri.parse(client.baseUrl).host;
    return NetworkImage(url, headers: own ? client.authHeaders : null);
  }
  if (url.startsWith('/')) {
    return NetworkImage(
      client.serverUri(url).toString(),
      headers: client.authHeaders,
    );
  }
  return null;
}

/// A Markdown image in a reply, tap to see it full screen.
class MarkdownImage extends ConsumerWidget {
  const MarkdownImage({super.key, required this.url, this.alt = ''});
  final String url;
  final String alt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = markdownImage(url, ref.watch(clientProvider));
    if (image == null) return Text(alt.isEmpty ? url : alt);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: GestureDetector(
        onTap: () => _openPhoto(context, image),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: Image(
              image: image,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) =>
                  _FileTile(name: alt.isEmpty ? url : alt),
            ),
          ),
        ),
      ),
    );
  }
}

void _openPhoto(BuildContext context, ImageProvider image) =>
    showBeside(context, image, (_) => _PhotoView(image: image));

class _Thumb extends StatelessWidget {
  const _Thumb({required this.image, required this.name, required this.size});
  final ImageProvider image;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => _openPhoto(context, image),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image(
        image: image,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _FileTile(name: name),
      ),
    ),
  );
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({
    required this.uri,
    required this.headers,
    required this.name,
  });
  final Uri uri;
  final Map<String, String> headers;
  final String name;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => VideoView(uri: uri, headers: headers, title: name),
      ),
    ),
    child: Container(
      width: 160,
      height: 110,
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          const Expanded(
            child: Center(
              child: Icon(
                Icons.play_circle_fill,
                color: Colors.white,
                size: 44,
              ),
            ),
          ),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

/// Plays a video from the server, signed in.
class VideoView extends StatefulWidget {
  const VideoView({
    super.key,
    required this.uri,
    required this.headers,
    required this.title,
  });
  final Uri uri;
  final Map<String, String> headers;
  final String title;

  @override
  State<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<VideoView> {
  late final VideoPlayerController _video = VideoPlayerController.networkUrl(
    widget.uri,
    httpHeaders: widget.headers,
  );
  Object? _error;

  @override
  void initState() {
    super.initState();
    _video.addListener(_changed);
    _video
        .initialize()
        .then((_) {
          if (mounted) _video.play();
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e);
        });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _video.removeListener(_changed);
    _video.dispose();
    super.dispose();
  }

  String _time(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final v = _video.value;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  "Couldn't play this video.\n$_error",
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            )
          : !v.isInitialized
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Center(
                    child: GestureDetector(
                      onTap: () => v.isPlaying ? _video.pause() : _video.play(),
                      child: AspectRatio(
                        aspectRatio: v.aspectRatio,
                        child: VideoPlayer(_video),
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      IconButton(
                        color: Colors.white,
                        tooltip: v.isPlaying ? 'Pause' : 'Play',
                        onPressed: () =>
                            v.isPlaying ? _video.pause() : _video.play(),
                        icon: Icon(
                          v.isPlaying ? Icons.pause : Icons.play_arrow,
                        ),
                      ),
                      Expanded(
                        child: VideoProgressIndicator(
                          _video,
                          allowScrubbing: true,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          '${_time(v.position)} / ${_time(v.duration)}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
      leading: panelLeading(context),
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
    ),
    body: Center(
      child: InteractiveViewer(maxScale: 5, child: Image(image: image)),
    ),
  );
}

/// The largest a photo is sent: 2048 on a side, or smaller when Settings >
/// Interface > Image compression sets a size (in [channels] only when that
/// setting says so too).
(double, double) imageLimits(Map? ui, {bool channels = false}) {
  const most = 2048.0;
  if (ui?['imageCompression'] != true) return (most, most);
  if (channels && ui?['imageCompressionInChannels'] == false) {
    return (most, most);
  }
  final size = (ui?['imageCompressionSize'] as Map?) ?? const {};
  double side(Object? v) {
    final n = double.tryParse('${v ?? ''}');
    return n == null || n <= 0 ? most : math.min(n, most);
  }

  return (side(size['width']), side(size['height']));
}
