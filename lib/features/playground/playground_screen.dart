import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/attachments.dart' show MarkdownImage;
import '../chat/chat_controller.dart';
import '../chat/chat_screen.dart' show readingInset;

/// One message in the playground, any role, editable.
class _Turn {
  _Turn(this.role, [String text = ''])
    : text = TextEditingController(text: text);
  String role;
  final TextEditingController text;
}

/// The playground's messages as the web exports them: model, system and
/// messages, ready for the chat completions API.
String playgroundJson(
  String? model,
  String system,
  List<({String role, String content})> turns,
) => const JsonEncoder.withIndent('  ').convert({
  'model': ?model,
  'messages': [
    if (system.trim().isNotEmpty) {'role': 'system', 'content': system.trim()},
    for (final t in turns)
      if (t.content.trim().isNotEmpty) {'role': t.role, 'content': t.content},
  ],
});

/// The playground's messages as plain text, one block per message.
String playgroundText(
  String system,
  List<({String role, String content})> turns,
) => [
  if (system.trim().isNotEmpty) '### SYSTEM\n${system.trim()}',
  for (final t in turns)
    if (t.content.trim().isNotEmpty)
      '### ${t.role.toUpperCase()}\n${t.content.trim()}',
].join('\n\n');

/// The web's Playground: try a model on hand-written messages, continue a
/// piece of text, or make images, without making a chat. Nothing here is
/// saved on the server.
class PlaygroundScreen extends StatelessWidget {
  const PlaygroundScreen({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Playground'),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Chat'),
            Tab(text: 'Completions'),
            Tab(text: 'Images'),
          ],
        ),
      ),
      body: const TabBarView(
        children: [ChatPlayground(), CompletionPlayground(), ImagePlayground()],
      ),
    ),
  );
}

/// Hand-written messages to any role, run against a model.
class ChatPlayground extends ConsumerStatefulWidget {
  const ChatPlayground({super.key});

  @override
  ConsumerState<ChatPlayground> createState() => _ChatPlaygroundState();
}

class _ChatPlaygroundState extends ConsumerState<ChatPlayground> {
  String? _model;
  final _system = TextEditingController();
  final _turns = [_Turn('user')];
  final _temperature = TextEditingController();
  StreamSubscription<String>? _run;
  String? _error;

  bool get _running => _run != null;

  @override
  void dispose() {
    _run?.cancel();
    super.dispose();
  }

  void _start() {
    final model = _model;
    if (model == null) {
      setState(() => _error = 'Pick a model first');
      return;
    }
    final messages = [
      if (_system.text.trim().isNotEmpty)
        {'role': 'system', 'content': _system.text.trim()},
      for (final t in _turns)
        if (t.text.text.trim().isNotEmpty)
          {'role': t.role, 'content': t.text.text},
    ];
    if (messages.isEmpty) {
      setState(() => _error = 'Write a message first');
      return;
    }
    final temperature = double.tryParse(_temperature.text.trim());
    final reply = _Turn('assistant');
    setState(() {
      _error = null;
      _turns.add(reply);
    });
    _run = ref
        .read(clientProvider)
        .streamCompletion(
          model: model,
          messages: messages,
          extraParams: {'temperature': ?temperature},
        )
        .listen(
          (delta) => setState(() => reply.text.text += delta),
          onError: (Object e) => setState(() {
            _error = '$e';
            _run = null;
          }),
          onDone: () => setState(() {
            _run = null;
            // Ready for the next message.
            _turns.add(_Turn('user'));
          }),
          cancelOnError: true,
        );
  }

  void _stop() {
    _run?.cancel();
    setState(() => _run = null);
  }

  List<({String role, String content})> get _plain => [
    for (final t in _turns) (role: t.role, content: t.text.text),
  ];

  Future<void> _export(String how) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final json = playgroundJson(_model, _system.text, _plain);
      if (how == 'copy') {
        await Clipboard.setData(ClipboardData(text: json));
        messenger.showSnackBar(const SnackBar(content: Text('Copied')));
        return;
      }
      final text = how == 'txt';
      final name = 'playground.${text ? 'txt' : 'json'}';
      final saved = await FilePicker.saveFile(
        fileName: name,
        bytes: Uint8List.fromList(
          utf8.encode(text ? playgroundText(_system.text, _plain) : json),
        ),
        mimeType: text ? 'text/plain' : 'application/json',
      );
      if (saved != null) {
        messenger.showSnackBar(SnackBar(content: Text('Saved $name')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final models = ref.watch(modelsProvider).value ?? const [];
    _model ??= models.isEmpty ? null : models.first.id;
    final muted = context.nexus.muted;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _running ? _stop : _start,
        icon: Icon(_running ? Icons.stop : Icons.play_arrow),
        label: Text(_running ? 'Stop' : 'Run'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          readingInset(context, 16),
          8,
          readingInset(context, 16),
          96,
        ),
        children: [
          DropdownButtonFormField<String>(
            initialValue: _model,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Model'),
            items: [
              for (final m in models)
                DropdownMenuItem(
                  value: m.id,
                  child: Text(m.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: _running ? null : (v) => setState(() => _model = v),
          ),
          TextField(
            controller: _temperature,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Temperature',
              hintText: 'Model default',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _system,
            minLines: 2,
            maxLines: null,
            decoration: const InputDecoration(
              labelText: 'System',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          for (final (i, t) in _turns.indexed)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              elevation: 0,
              color: t.role == 'user'
                  ? context.nexus.userBubble
                  : scheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        TextButton(
                          // Tap to switch who said it, as on the web.
                          onPressed: _running
                              ? null
                              : () => setState(
                                  () => t.role = t.role == 'user'
                                      ? 'assistant'
                                      : 'user',
                                ),
                          child: Text(
                            t.role == 'user' ? 'USER' : 'ASSISTANT',
                            style: const TextStyle(letterSpacing: 1),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Remove',
                          visualDensity: VisualDensity.compact,
                          onPressed: _running
                              ? null
                              : () => setState(() => _turns.removeAt(i)),
                          icon: Icon(Icons.close, size: 18, color: muted),
                        ),
                      ],
                    ),
                    TextField(
                      controller: t.text,
                      maxLines: null,
                      decoration: InputDecoration.collapsed(
                        hintText: t.role == 'user'
                            ? 'Enter a user message'
                            : 'Enter an assistant message',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _running
                  ? null
                  : () => setState(
                      () => _turns.add(
                        _Turn(
                          _turns.isNotEmpty && _turns.last.role == 'user'
                              ? 'assistant'
                              : 'user',
                        ),
                      ),
                    ),
              icon: const Icon(Icons.add),
              label: const Text('Add message'),
            ),
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: () => _export('copy'),
                icon: const Icon(Icons.copy),
                label: const Text('Copy JSON'),
              ),
              PopupMenuButton<String>(
                tooltip: 'Export',
                onSelected: _export,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'json',
                    child: Text('Export chat (.json)'),
                  ),
                  PopupMenuItem(value: 'txt', child: Text('Plain text (.txt)')),
                ],
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.download_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('Export'),
                    ],
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _running
                    ? null
                    : () => setState(() {
                        _turns
                          ..clear()
                          ..add(_Turn('user'));
                        _error = null;
                      }),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Clear'),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
        ],
      ),
    );
  }
}

/// A model dropdown shared by the playground's tabs.
Widget _modelPicker(
  List<({String id, String name})> models,
  String? value,
  ValueChanged<String?>? onChanged, {
  String label = 'Model',
}) => DropdownButtonFormField<String>(
  initialValue: models.any((m) => m.id == value) ? value : null,
  isExpanded: true,
  decoration: InputDecoration(labelText: label),
  items: [
    for (final m in models)
      DropdownMenuItem(
        value: m.id,
        child: Text(m.name, overflow: TextOverflow.ellipsis),
      ),
  ],
  onChanged: onChanged,
);

/// Text the model continues, written straight into the box, as the web's
/// Completions tab.
class CompletionPlayground extends ConsumerStatefulWidget {
  const CompletionPlayground({super.key});

  @override
  ConsumerState<CompletionPlayground> createState() =>
      _CompletionPlaygroundState();
}

class _CompletionPlaygroundState extends ConsumerState<CompletionPlayground> {
  String? _model;
  final _system = TextEditingController();
  final _text = TextEditingController();
  StreamSubscription<String>? _run;
  String? _error;

  @override
  void dispose() {
    _run?.cancel();
    _system.dispose();
    _text.dispose();
    super.dispose();
  }

  void _start() {
    final model = _model;
    if (model == null || _text.text.trim().isEmpty) {
      setState(() => _error = 'Pick a model and write something first');
      return;
    }
    setState(() => _error = null);
    _run = ref
        .read(clientProvider)
        .streamCompletion(
          model: model,
          messages: [
            if (_system.text.trim().isNotEmpty)
              {'role': 'system', 'content': _system.text.trim()},
            {'role': 'user', 'content': _text.text},
          ],
        )
        .listen(
          (delta) => setState(() => _text.text += delta),
          onError: (Object e) => setState(() {
            _error = '$e';
            _run = null;
          }),
          onDone: () => setState(() => _run = null),
          cancelOnError: true,
        );
  }

  @override
  Widget build(BuildContext context) {
    final models = <({String id, String name})>[
      for (final m in ref.watch(modelsProvider).value ?? const [])
        (id: m.id, name: m.name),
    ];
    _model ??= models.isEmpty ? null : models.first.id;
    final running = _run != null;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: running
            ? () {
                _run?.cancel();
                setState(() => _run = null);
              }
            : _start,
        icon: Icon(running ? Icons.stop : Icons.play_arrow),
        label: Text(running ? 'Stop' : 'Run'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          readingInset(context, 16),
          8,
          readingInset(context, 16),
          96,
        ),
        children: [
          _modelPicker(
            models,
            _model,
            running ? null : (v) => setState(() => _model = v),
          ),
          TextField(
            controller: _system,
            maxLines: null,
            decoration: const InputDecoration(
              labelText: 'System',
              hintText: 'You\'re a helpful assistant.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            minLines: 12,
            maxLines: null,
            readOnly: running,
            decoration: const InputDecoration(
              hintText: 'Write the start; the model carries on from there',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// The image models the server can use, or null when image making is off.
final imageModelsProvider =
    FutureProvider.autoDispose<List<({String id, String name})>?>((ref) async {
      final config = await ref.watch(serverConfigProvider.future);
      final features = (config['features'] as Map?) ?? const {};
      if (features['enable_image_generation'] != true) return null;
      try {
        final res = await ref
            .watch(clientProvider)
            .send('GET', '/api/v1/images/models');
        return [
          for (final m in res as List? ?? const [])
            if (m is Map) (id: '${m['id']}', name: '${m['name'] ?? m['id']}'),
        ];
      } on ApiException catch (e) {
        if (e.statusCode == 403 || e.statusCode == 404) return null;
        rethrow;
      }
    });

/// Makes images from a description with the server's image engine.
class ImagePlayground extends ConsumerStatefulWidget {
  const ImagePlayground({super.key});

  @override
  ConsumerState<ImagePlayground> createState() => _ImagePlaygroundState();
}

class _ImagePlaygroundState extends ConsumerState<ImagePlayground> {
  String? _model;
  final _prompt = TextEditingController();
  final _size = TextEditingController();
  int _count = 1;
  bool _busy = false;
  String? _error;

  /// Newest first.
  final _images = <String>[];

  /// Pictures to change instead of starting fresh, as data URLs.
  final _inputs = <String>[];

  Future<void> _addImage() async {
    final picked = await ImagePicker().pickMultiImage(
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 90,
    );
    for (final f in picked) {
      final bytes = await f.readAsBytes();
      final type = f.name.toLowerCase().endsWith('.png') ? 'png' : 'jpeg';
      _inputs.add('data:image/$type;base64,${base64Encode(bytes)}');
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _prompt.dispose();
    _size.dispose();
    super.dispose();
  }

  Future<void> _make() async {
    if (_prompt.text.trim().isEmpty) {
      setState(() => _error = 'Describe the picture first');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref
          .read(clientProvider)
          .send(
            'POST',
            // With pictures added, the server changes them instead.
            _inputs.isEmpty
                ? '/api/v1/images/generations'
                : '/api/v1/images/edit',
            body: {
              if (_inputs.isNotEmpty)
                'image': _inputs.length == 1 ? _inputs.first : _inputs,
              'prompt': _prompt.text.trim(),
              'model': ?_model,
              if (_size.text.trim().isNotEmpty) 'size': _size.text.trim(),
              'n': _count,
            },
          );
      final urls = [
        for (final i in res as List? ?? const [])
          if (i is Map && i['url'] != null) '${i['url']}',
      ];
      setState(() => _images.insertAll(0, urls));
    } catch (e) {
      setState(() => _error = '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save(String url) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final client = ref.read(clientProvider);
      final bytes = url.startsWith('data:')
          ? base64Decode(url.substring(url.indexOf(',') + 1))
          : await client.getBytes(url);
      final saved = await FilePicker.saveFile(
        fileName: 'image-${DateTime.now().millisecondsSinceEpoch}.png',
        bytes: Uint8List.fromList(bytes),
        mimeType: 'image/png',
      );
      if (saved != null) {
        messenger.showSnackBar(const SnackBar(content: Text('Image saved')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final models = ref.watch(imageModelsProvider);
    final muted = context.nexus.muted;
    if (models.value == null && models.hasValue) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Image making isn\'t turned on for you on this server.',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted),
          ),
        ),
      );
    }
    final list = models.value ?? const [];
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _make,
        icon: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.brush_outlined),
        label: Text(_busy ? 'Making…' : 'Make'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          readingInset(context, 16),
          8,
          readingInset(context, 16),
          96,
        ),
        children: [
          if (list.isNotEmpty)
            _modelPicker(
              list,
              _model,
              _busy ? null : (v) => setState(() => _model = v),
              label: 'Image model (server default if empty)',
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _size,
                  decoration: const InputDecoration(
                    labelText: 'Size',
                    hintText: 'Default, or e.g. 1024x1024',
                  ),
                ),
              ),
              const SizedBox(width: 16),
              DropdownButton<int>(
                value: _count,
                items: [
                  for (final n in [1, 2, 3, 4])
                    DropdownMenuItem(
                      value: n,
                      child: Text(n == 1 ? '1 image' : '$n images'),
                    ),
                ],
                onChanged: _busy ? null : (v) => setState(() => _count = v!),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _prompt,
            minLines: 3,
            maxLines: null,
            decoration: InputDecoration(
              labelText: _inputs.isEmpty
                  ? 'Describe the picture'
                  : 'Describe the change',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final (i, data) in _inputs.indexed)
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        base64Decode(data.substring(data.indexOf(',') + 1)),
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: GestureDetector(
                        onTap: () => setState(() => _inputs.removeAt(i)),
                        child: const CircleAvatar(
                          radius: 11,
                          child: Icon(
                            Icons.close,
                            size: 14,
                            semanticLabel: 'Remove image',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              TextButton.icon(
                onPressed: _busy ? null : _addImage,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(
                  _inputs.isEmpty ? 'Add an image to change' : 'Add image',
                ),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          for (final url in _images)
            Stack(
              children: [
                MarkdownImage(url: url),
                Positioned(
                  right: 8,
                  top: 14,
                  child: IconButton.filledTonal(
                    tooltip: 'Save to phone',
                    onPressed: () => _save(url),
                    icon: const Icon(Icons.download_outlined),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
