/// A model's voice avatar, as the web's: a 3D VRM character that shows in
/// voice calls, breathing and blinking, moving its mouth as it speaks and
/// leaning in as it listens. The model's own animations (.vrma) can replace
/// the idle, listening and speaking motion, and named gestures play when the
/// voice model asks for one. Saved in the model's meta.voice_avatar.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/theme.dart';

const avatarStates = ['idle', 'listening', 'speaking'];

/// The largest avatar the web accepts.
const avatarMaxBytes = 25 * 1024 * 1024;

typedef AvatarGesture = ({String name, String description, String fileId});

class VoiceAvatarConfig {
  const VoiceAvatarConfig({
    required this.fileId,
    this.states = const {},
    this.gestures = const [],
  });

  /// meta.voice_avatar, or null when the model has none.
  static VoiceAvatarConfig? fromMeta(Map? meta) {
    final v = meta?['voice_avatar'];
    if (v is! Map || v['file_id'] is! String) return null;
    return VoiceAvatarConfig(
      fileId: v['file_id'] as String,
      states: {
        for (final s in avatarStates)
          if (((v['states'] as Map?)?[s] as Map?)?['file_id']
              case final String id)
            s: id,
      },
      gestures: [
        for (final g in (v['gestures'] as List? ?? const []).whereType<Map>())
          if (g['name'] is String && g['file_id'] is String)
            (
              name: g['name'] as String,
              description: '${g['description'] ?? ''}',
              fileId: g['file_id'] as String,
            ),
      ],
    );
  }

  final String fileId;

  /// State name (idle, listening, speaking) to its animation file.
  final Map<String, String> states;
  final List<AvatarGesture> gestures;

  VoiceAvatarConfig copyWith({
    String? fileId,
    Map<String, String>? states,
    List<AvatarGesture>? gestures,
  }) => VoiceAvatarConfig(
    fileId: fileId ?? this.fileId,
    states: states ?? this.states,
    gestures: gestures ?? this.gestures,
  );

  Map<String, dynamic> toJson() => {
    'file_id': fileId,
    if (states.isNotEmpty)
      'states': {
        for (final e in states.entries) e.key: {'file_id': e.value},
      },
    if (gestures.isNotEmpty)
      'gestures': [
        for (final g in gestures)
          {'name': g.name, 'description': g.description, 'file_id': g.fileId},
      ],
  };
}

/// Why [bytes] can't be a voice avatar, or null when it can: a binary VRM
/// (0.x or 1.0) with a humanoid rig and everything embedded, as the web
/// checks before upload.
String? checkVrm(Uint8List bytes) {
  if (bytes.length > avatarMaxBytes) return 'Avatar must be at most 25 MiB.';
  if (bytes.length < 28) return 'Upload a VRM 0.x or VRM 1.0 file.';
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(0, Endian.little) != 0x46546c67 ||
      data.getUint32(4, Endian.little) != 2 ||
      data.getUint32(8, Endian.little) != bytes.length ||
      data.getUint32(16, Endian.little) != 0x4e4f534a) {
    return 'Upload a binary VRM file.';
  }
  final length = data.getUint32(12, Endian.little);
  if (20 + length > bytes.length) return 'Invalid avatar container.';
  Map json;
  try {
    json = jsonDecode(utf8.decode(bytes.sublist(20, 20 + length))) as Map;
  } catch (_) {
    return 'Invalid avatar container.';
  }
  final ext = (json['extensions'] as Map?) ?? const {};
  final vrm = (ext['VRMC_vrm'] ?? ext['VRM']) as Map?;
  final humanoid = vrm?['humanoid'] as Map?;
  final raw = humanoid?['humanBones'];
  if (raw == null) {
    return 'This model needs a VRM humanoid rig. A plain GLB is not enough.';
  }
  // VRM 0.x lists bones; 1.0 maps names to them.
  final bones = <String, Object?>{
    if (raw is List)
      for (final b in raw.whereType<Map>()) '${b['bone']}': b['node']
    else if (raw is Map)
      for (final e in raw.entries) '${e.key}': (e.value as Map?)?['node'],
  };
  final nodes = (json['nodes'] as List?)?.length ?? 0;
  for (final name in const [
    'hips',
    'spine',
    'head',
    'leftUpperArm',
    'rightUpperArm',
    'leftLowerArm',
    'rightLowerArm',
  ]) {
    final node = bones[name];
    if (node is! int || node >= nodes) {
      return 'Avatar is missing its $name bone.';
    }
  }
  final buffers = json['buffers'] as List? ?? const [];
  final images = json['images'] as List? ?? const [];
  if (buffers.length != 1 ||
      (buffers.first as Map)['uri'] != null ||
      images.whereType<Map>().any(
        (i) => i['uri'] != null || i['bufferView'] is! int,
      )) {
    return 'Embed all textures and buffers in the VRM file. External '
        'resources are not supported.';
  }
  if (nodes > 512 || images.length > 32) {
    return 'This avatar is too complex for a voice call. Use a lighter '
        'export.';
  }
  return null;
}

/// The page the avatar draws in; the renderer is bundled with the app.
Future<String> avatarPage() async {
  final js = await rootBundle.loadString('assets/avatar/avatar.js');
  return '''<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}
canvas{width:100%;height:100%;display:block}</style></head>
<body><canvas id="avatar"></canvas><script>$js</script></body></html>''';
}

/// The avatar on the voice call showing now, for gestures the server asks
/// for; null when none is.
AvatarHandle? activeAvatar;

/// Lets the call screen play a gesture on the avatar it shows.
class AvatarHandle {
  _VoiceAvatarViewState? _view;

  /// Plays [name] once: 'started', or 'unavailable' when the avatar isn't
  /// showing or has no such gesture.
  Future<String> gesture(String name) async =>
      await _view?._gesture(name) ?? 'unavailable';

  Future<void> cancelGesture() async => _view?._run('avatar.cancelGesture()');

  bool get showing => _view?._ready ?? false;
}

/// The avatar, drawn over a transparent background. [onFailed] hears when
/// it can't show (the call falls back to its usual circle).
class VoiceAvatarView extends StatefulWidget {
  const VoiceAvatarView({
    super.key,
    required this.client,
    required this.config,
    required this.speaking,
    required this.listening,
    required this.level,
    this.handle,
    this.onFailed,
  });

  final OpenWebUiClient client;
  final VoiceAvatarConfig config;
  final bool speaking;
  final bool listening;
  final double level;
  final AvatarHandle? handle;
  final ValueChanged<String>? onFailed;

  @override
  State<VoiceAvatarView> createState() => _VoiceAvatarViewState();
}

class _VoiceAvatarViewState extends State<VoiceAvatarView> {
  late final WebViewController _web;
  bool _ready = false;
  bool _failed = false;
  bool _pageLoaded = false;
  String _sent = '';

  @override
  void initState() {
    super.initState();
    widget.handle?._view = this;
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('AvatarBridge', onMessageReceived: _onMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (_pageLoaded) return;
            _pageLoaded = true;
            unawaited(_feed());
          },
        ),
      );
    unawaited(avatarPage().then((html) => _web.loadHtmlString(html)));
  }

  @override
  void dispose() {
    if (widget.handle?._view == this) widget.handle?._view = null;
    super.dispose();
  }

  void _fail(String why) {
    if (_failed || !mounted) return;
    setState(() => _failed = true);
    widget.onFailed?.call(why);
  }

  Future<void> _run(String js) async {
    try {
      await _web.runJavaScript(js);
    } catch (_) {}
  }

  /// Downloads the avatar and its animations and hands them to the page.
  Future<void> _feed() async {
    try {
      Future<Uint8List> file(String id) async => Uint8List.fromList(
        await widget.client.getBytes(
          '/api/v1/files/${Uri.encodeComponent(id)}/content',
        ),
      );
      final vrm = await file(widget.config.fileId);
      final problem = checkVrm(vrm);
      if (problem != null) return _fail(problem);
      final anims = {
        for (final e in widget.config.states.entries) 'state:${e.key}': e.value,
        for (final g in widget.config.gestures) g.name: g.fileId,
      };
      for (final e in anims.entries) {
        try {
          final bytes = await file(e.value);
          await _web.runJavaScript(
            'avatar.animation(${jsonEncode(e.key)}, '
            '${jsonEncode(base64Encode(bytes))})',
          );
        } catch (_) {
          // A missing animation leaves the built-in motion.
        }
      }
      final text = base64Encode(vrm);
      const step = 1 << 20;
      for (var i = 0; i < text.length; i += step) {
        final end = i + step < text.length ? i + step : text.length;
        await _web.runJavaScript(
          'avatar.chunk(${jsonEncode(text.substring(i, end))})',
        );
      }
      await _web.runJavaScript('avatar.load()');
    } catch (e) {
      _fail('The avatar could not be loaded: $e');
    }
  }

  void _onMessage(JavaScriptMessage m) {
    Map? msg;
    try {
      msg = jsonDecode(m.message) as Map?;
    } catch (_) {}
    switch (msg?['type']) {
      case 'ready':
        if (mounted) setState(() => _ready = true);
        _sync();
      case 'error':
        _fail('${msg?['message'] ?? 'The avatar could not be shown.'}');
    }
  }

  Future<String> _gesture(String name) async {
    if (!_ready) return 'unavailable';
    try {
      final r = await _web.runJavaScriptReturningResult(
        'avatar.gesture(${jsonEncode(name)})',
      );
      return '$r'.replaceAll('"', '') == 'started' ? 'started' : 'unavailable';
    } catch (_) {
      return 'unavailable';
    }
  }

  void _sync() {
    if (!_ready) return;
    final signals = jsonEncode({
      'speaking': widget.speaking,
      'listening': widget.listening,
      'level': (widget.level * 20).round() / 20,
    });
    if (signals == _sent) return;
    _sent = signals;
    unawaited(_run('avatar.signals($signals)'));
  }

  @override
  void didUpdateWidget(VoiceAvatarView old) {
    super.didUpdateWidget(old);
    if (old.handle != widget.handle) {
      if (old.handle?._view == this) old.handle?._view = null;
      widget.handle?._view = this;
    }
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return const SizedBox.shrink();
    return Stack(
      alignment: Alignment.center,
      children: [
        WebViewWidget(controller: _web),
        if (!_ready)
          const SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }
}

/// The model editor's Voice avatar setting: the avatar file, its state
/// animations and gestures. Files upload as they're picked; returns the
/// new setting (null to remove it), or the old one on Cancel.
Future<(VoiceAvatarConfig?,)?> editVoiceAvatar(
  BuildContext context,
  OpenWebUiClient client,
  VoiceAvatarConfig? current,
) => Navigator.push<(VoiceAvatarConfig?,)>(
  context,
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => VoiceAvatarEditor(client: client, initial: current),
  ),
);

class VoiceAvatarEditor extends StatefulWidget {
  const VoiceAvatarEditor({super.key, required this.client, this.initial});
  final OpenWebUiClient client;
  final VoiceAvatarConfig? initial;

  @override
  State<VoiceAvatarEditor> createState() => _VoiceAvatarEditorState();
}

class _VoiceAvatarEditorState extends State<VoiceAvatarEditor> {
  late VoiceAvatarConfig? _config = widget.initial;
  String? _busy;
  String? _problem;

  /// Picks a file ending in one of [extensions] and uploads it, after
  /// [check]; returns the server's file id.
  Future<String?> _upload(
    String what,
    List<String> extensions, [
    String? Function(Uint8List)? check,
  ]) async {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty || !mounted) return null;
    final f = picked.first;
    final name = f.name.toLowerCase();
    if (!extensions.any(name.endsWith)) {
      setState(() => _problem = 'Pick a ${extensions.join(' or ')} file.');
      return null;
    }
    setState(() {
      _busy = what;
      _problem = null;
    });
    try {
      final bytes = Uint8List.fromList(await f.readAsBytes());
      final problem = check?.call(bytes);
      if (problem != null) {
        setState(() => _problem = problem);
        return null;
      }
      final res = await widget.client.uploadFile(
        bytes,
        f.name,
        contentType: 'application/octet-stream',
        process: false,
      );
      return res['id'] as String;
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
      return null;
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _pickAvatar() async {
    final id = await _upload('avatar', const ['.vrm'], checkVrm);
    if (id == null) return;
    setState(
      () => _config =
          _config?.copyWith(fileId: id) ?? VoiceAvatarConfig(fileId: id),
    );
  }

  Future<void> _pickState(String state) async {
    final id = await _upload(state, const ['.vrma']);
    if (id == null || _config == null) return;
    setState(
      () =>
          _config = _config!.copyWith(states: {..._config!.states, state: id}),
    );
  }

  Future<void> _addGesture() async {
    final name = TextEditingController();
    final description = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New gesture'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'wave',
              ),
            ),
            TextField(
              controller: description,
              decoration: const InputDecoration(
                labelText: 'When to use it',
                hintText: 'Greeting someone',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Pick animation'),
          ),
        ],
      ),
    );
    final n = name.text.trim();
    final d = description.text.trim();
    // Not disposed: the dialog's text field still builds while it closes.
    if (ok != true || n.isEmpty || _config == null) return;
    final id = await _upload(n, const ['.vrma']);
    if (id == null) return;
    setState(
      () => _config = _config!.copyWith(
        gestures: [
          ..._config!.gestures.where((g) => g.name != n),
          (name: n, description: d, fileId: id),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final c = _config;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Close avatar setup',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Voice avatar'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy != null
                  ? null
                  : () => Navigator.pop(context, (c,)),
              child: const Text('Apply'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'A 3D character (a .vrm file) that shows in voice calls with '
            'this model. It breathes, blinks, and moves its mouth as it '
            'speaks.',
            style: TextStyle(color: muted),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.face_retouching_natural),
            title: Text(c == null ? 'Default' : 'Custom avatar'),
            subtitle: Text(
              c == null ? 'No avatar: calls show a circle.' : 'Avatar file set',
            ),
            trailing: _busy == 'avatar'
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed: _busy == null ? _pickAvatar : null,
                    child: Text(c == null ? 'Upload .vrm' : 'Replace'),
                  ),
          ),
          if (c != null) ...[
            const Divider(),
            Text('Animations', style: Theme.of(context).textTheme.titleSmall),
            Text(
              'Optional .vrma files; without them the avatar uses its own '
              'motion.',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            for (final s in avatarStates)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${s[0].toUpperCase()}${s.substring(1)}'),
                subtitle: Text(
                  c.states[s] == null ? 'Built-in motion' : 'Custom animation',
                ),
                trailing: _busy == s
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (c.states[s] != null)
                            IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(
                                () => _config = c.copyWith(
                                  states: {...c.states}..remove(s),
                                ),
                              ),
                            ),
                          TextButton(
                            onPressed: _busy == null
                                ? () => _pickState(s)
                                : null,
                            child: const Text('Upload'),
                          ),
                        ],
                      ),
              ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Gestures',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                TextButton.icon(
                  onPressed: _busy == null ? _addGesture : null,
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ],
            ),
            Text(
              'The voice model can play these during a call.',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            for (final g in c.gestures)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(g.name),
                subtitle: g.description.isEmpty ? null : Text(g.description),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(
                    () => _config = c.copyWith(
                      gestures: [
                        for (final x in c.gestures)
                          if (x.name != g.name) x,
                      ],
                    ),
                  ),
                ),
              ),
            const Divider(),
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: _busy == null
                  ? () => setState(() => _config = null)
                  : null,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove avatar'),
            ),
          ],
          if (_busy != null &&
              _busy != 'avatar' &&
              !avatarStates.contains(_busy))
            const LinearProgressIndicator(),
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _problem!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
