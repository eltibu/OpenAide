/// A skill's files (SKILL.md and whatever comes with it), its .skill
/// export and importing skills from files, as the web's skill pages.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../../core/i18n/app_strings.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(text))));

String _seg(String id) => Uri.encodeComponent(id);

/// One file change for the server: put, move or delete.
Map<String, dynamic> putFile(String path, List<int> bytes) {
  try {
    final text = utf8.decode(bytes);
    if (!text.contains('\u0000')) {
      return {'op': 'put', 'path': path, 'content': text};
    }
  } on FormatException {
    // Not text: sent as base64 below.
  }
  return {
    'op': 'put',
    'path': path,
    'content': base64Encode(bytes),
    'encoding': 'base64',
  };
}

/// Why [path] can't be a skill file name, or null when it can.
String? skillPathProblem(String path) {
  if (path.trim().isEmpty) return 'Give it a name';
  if (path.startsWith('/') || path.contains('\\') || path.contains(':')) {
    return 'Use a relative path like scripts/run.py';
  }
  if (path.split('/').any((p) => p.isEmpty || p == '.' || p == '..')) {
    return 'That path is not allowed';
  }
  return null;
}

/// Saves the skill as a .skill package.
Future<void> exportSkillFile(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  try {
    final bytes = await ref.read(clientProvider).getBytes(
      '/api/v1/skills/export',
      {'format': 'skill', 'ids': id},
    );
    final name = '$id.skill';
    final saved = await FilePicker.saveFile(
      fileName: name,
      bytes: Uint8List.fromList(bytes),
    );
    if (saved != null && context.mounted) _say(context, 'Saved $name');
  } catch (e) {
    if (context.mounted) _say(context, '$e');
  }
}

class SkillFilesScreen extends ConsumerStatefulWidget {
  const SkillFilesScreen({super.key, required this.id, required this.name});
  final String id, name;

  @override
  ConsumerState<SkillFilesScreen> createState() => _SkillFilesState();
}

class _SkillFilesState extends ConsumerState<SkillFilesScreen> {
  OpenWebUiClient get _client => ref.read(clientProvider);
  String get _base => '/api/v1/skills/id/${_seg(widget.id)}';
  List<Map<String, dynamic>>? _files;
  String? _version;
  Object? _error;
  bool _busy = false;

  /// Whether a change was saved, so the editor reloads.
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = (await _client.send('GET', '$_base/files')) as Map;
      _version = res['version_id']?.toString();
      _files = [
        for (final f in res['files'] as List? ?? const [])
          if (f is Map) f.cast<String, dynamic>(),
      ]..sort((a, b) => '${a['path']}'.compareTo('${b['path']}'));
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  /// Applies [ops] to the skill's files.
  Future<bool> _apply(List<Map<String, dynamic>> ops) async {
    setState(() => _busy = true);
    try {
      await _client.send(
        'POST',
        '$_base/update',
        body: {
          'id': widget.id,
          'name': widget.name,
          'operations': ops,
          'expected_version_id': _version,
        },
      );
      _changed = true;
      await _load();
      return true;
    } catch (e) {
      if (mounted) _say(context, '$e');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askPath(String title, {String start = ''}) async {
    final text = TextEditingController(text: start);
    String? problem;
    return showDialog<String>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: text,
            autofocus: true,
            decoration: InputDecoration(
              hintText: tr('references/notes.md'),
              errorText: problem,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d),
              child: const T('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final p = text.text.trim();
                final why = skillPathProblem(p);
                if (why != null) return set(() => problem = why);
                Navigator.pop(d, p);
              },
              child: const T('OK'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _newFile() async {
    final path = await _askPath('New File');
    if (path == null || !mounted) return;
    if (_files!.any((f) => f['path'] == path)) {
      return _say(context, '$path is already there');
    }
    final saved = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => _FileEditor(path: path, text: ''),
      ),
    );
    if (saved != null) await _apply([putFile(path, utf8.encode(saved))]);
  }

  Future<void> _upload() async {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    await _apply([
      for (final f in picked) putFile(f.name, await f.readAsBytes()),
    ]);
  }

  Future<void> _open(Map<String, dynamic> f) async {
    final path = '${f['path']}';
    try {
      final bytes = await _client.getBytes('$_base/files/content', {
        'path': path,
        'version_id': ?_version,
      });
      if (!mounted) return;
      if (f['encoding'] == 'base64') {
        return _say(context, '$path is not text (${bytes.length} bytes)');
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final saved = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => _FileEditor(path: path, text: text),
        ),
      );
      if (saved != null && saved != text) {
        await _apply([putFile(path, utf8.encode(saved))]);
      }
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  Future<void> _rename(Map<String, dynamic> f) async {
    final path = '${f['path']}';
    final to = await _askPath('Rename', start: path);
    if (to == null || to == path) return;
    await _apply([
      {'op': 'move', 'path': path, 'destination': to},
    ]);
  }

  Future<void> _delete(Map<String, dynamic> f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${f['path']}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const T('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _apply([
        {'op': 'delete', 'path': f['path']},
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    final muted = context.nexus.muted;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('${widget.name} files'),
          actions: [
            IconButton(
              tooltip: tr('Upload files'),
              icon: const Icon(Icons.upload_file),
              onPressed: _busy || files == null ? null : _upload,
            ),
            IconButton(
              tooltip: tr('New File'),
              icon: const Icon(Icons.note_add_outlined),
              onPressed: _busy || files == null ? null : _newFile,
            ),
          ],
        ),
        body: files == null
            ? Center(
                child: _error != null
                    ? Text("Couldn't load the files.\n$_error")
                    : const CircularProgressIndicator(),
              )
            : ListView(
                children: [
                  if (_busy) const LinearProgressIndicator(minHeight: 2),
                  for (final f in files)
                    ListTile(
                      leading: Icon(
                        f['encoding'] == 'base64'
                            ? Icons.insert_drive_file_outlined
                            : Icons.description_outlined,
                      ),
                      title: Text('${f['path']}'),
                      subtitle: Text(
                        _size(f['size']),
                        style: TextStyle(color: muted),
                      ),
                      onTap: () => _open(f),
                      trailing: f['path'] == 'SKILL.md'
                          ? null
                          : PopupMenuButton<String>(
                              enabled: !_busy,
                              onSelected: (v) =>
                                  v == 'rename' ? _rename(f) : _delete(f),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'rename',
                                  child: T('Rename'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: T('Delete'),
                                ),
                              ],
                            ),
                    ),
                ],
              ),
      ),
    );
  }
}

String _size(Object? bytes) {
  if (bytes is! num) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// One text file: pops with the new text on Save.
class _FileEditor extends StatefulWidget {
  const _FileEditor({required this.path, required this.text});
  final String path, text;

  @override
  State<_FileEditor> createState() => _FileEditorState();
}

class _FileEditorState extends State<_FileEditor> {
  late final _text = TextEditingController(text: widget.text);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.path),
      actions: [
        IconButton(
          tooltip: tr('Copy content'),
          icon: const Icon(Icons.copy),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _text.text));
            _say(context, 'Copied');
          },
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(
            onPressed: () => Navigator.pop(context, _text.text),
            child: const T('Save'),
          ),
        ),
      ],
    ),
    body: TextField(
      controller: _text,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(16),
      ),
    ),
  );
}

/// What to do with one skill found in the picked files.
class ImportChoice {
  ImportChoice(this.preview)
    : action = preview['id_taken'] == true ? 'skip' : 'create',
      id = TextEditingController(text: '${preview['id'] ?? ''}');
  final Map<String, dynamic> preview;
  String action;
  final TextEditingController id;

  Map<String, dynamic> decision() => {
    'action': action,
    if (action == 'copy' || action == 'create') 'id': id.text.trim(),
    if (action == 'replace')
      'expected_version_id': preview['expected_version_id'],
  };
}

/// Import skills from .skill, .zip, .json or SKILL.md files.
class SkillImportScreen extends ConsumerStatefulWidget {
  /// [fromLink] asks for a link instead of files, as the web's Import
  /// from link: the server fetches the skills there.
  const SkillImportScreen({super.key, this.fromLink = false});
  final bool fromLink;

  @override
  ConsumerState<SkillImportScreen> createState() => _SkillImportState();
}

class _SkillImportState extends ConsumerState<SkillImportScreen> {
  List<(List<int>, String)>? _picked;
  List<ImportChoice>? _choices;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.fromLink ? _link() : _pick(),
    );
  }

  Future<void> _pick() async {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) {
      if (mounted && _picked == null) Navigator.pop(context);
      return;
    }
    setState(() => _busy = true);
    await _preview([
      for (final f in picked) (await f.readAsBytes(), f.name),
    ]);
  }

  /// As the web: the server reads the link, and what it found is looked
  /// over like a skills.json file.
  Future<void> _link() async {
    final url = await askSkillLink(context);
    if (url == null) {
      if (mounted && _picked == null) Navigator.pop(context);
      return;
    }
    setState(() => _busy = true);
    try {
      final packages = await ref
          .read(clientProvider)
          .send('POST', '/api/v1/skills/load/url', body: {'url': url});
      await _preview([(utf8.encode(jsonEncode(packages)), 'skills.json')]);
    } catch (e) {
      if (mounted) {
        _say(context, '$e');
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _preview(List<(List<int>, String)> files) async {
    try {
      final res = await ref
          .read(clientProvider)
          .sendFiles('/api/v1/skills/import/preview', files);
      _picked = files;
      _choices = [
        for (final p in res as List? ?? const [])
          if (p is Map) ImportChoice(p.cast<String, dynamic>()),
      ];
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final res = await ref
          .read(clientProvider)
          .sendFiles(
            '/api/v1/skills/import',
            _picked!,
            fields: {
              'decisions': jsonEncode([
                for (final c in _choices!) c.decision(),
              ]),
            },
          );
      final results = [
        for (final r in res as List? ?? const [])
          if (r is Map) r,
      ];
      final saved = results.where((r) => r['status'] == 'saved').length;
      final errors = [
        for (final r in results)
          if (r['status'] == 'error') '${r['id']}: ${r['error']}',
      ];
      if (!mounted) return;
      if (errors.isEmpty) {
        _say(context, 'Imported $saved');
        Navigator.pop(context, true);
        return;
      }
      _say(context, 'Imported $saved. ${errors.join('; ')}');
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final choices = _choices;
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const T('Import skills'),
        actions: [
          if (choices != null && choices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: _busy || choices.every((c) => c.action == 'skip')
                    ? null
                    : _import,
                child: const T('Import selected'),
              ),
            ),
        ],
      ),
      body: choices == null
          ? Center(
              child: _busy
                  ? const CircularProgressIndicator()
                  : TextButton(
                      onPressed: widget.fromLink ? _link : _pick,
                      child: widget.fromLink
                          ? const T('Import from link')
                          : const T('Choose files'),
                    ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                if (choices.isEmpty)
                  T(
                    'No skills found in those files.',
                    style: TextStyle(color: muted),
                  ),
                for (final c in choices)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${c.preview['name'] ?? c.preview['id']}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if ('${c.preview['description'] ?? ''}'.isNotEmpty)
                            Text(
                              '${c.preview['description']}',
                              style: TextStyle(color: muted),
                            ),
                          Text(
                            '${(c.preview['files'] as List?)?.length ?? 0} files'
                            '${c.preview['id_taken'] == true ? ' · this ID is taken' : ''}',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final (a, label) in [
                                ('skip', 'Skip'),
                                if (c.preview['id_taken'] != true)
                                  ('create', 'Import')
                                else ...[
                                  ('copy', 'Import as a copy'),
                                  if (c.preview['can_replace'] == true)
                                    ('replace', 'Replace'),
                                ],
                              ])
                                ChoiceChip(
                                  label: Text(label),
                                  selected: c.action == a,
                                  onSelected: (_) =>
                                      setState(() => c.action = a),
                                ),
                            ],
                          ),
                          if (c.action == 'copy' || c.action == 'create')
                            TextField(
                              controller: c.id,
                              decoration: InputDecoration(
                                labelText: tr('Skill ID'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Asks for a link to skills (a GitHub folder, a .zip or a SKILL.md).
Future<String?> askSkillLink(BuildContext context) async {
  final url = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const T('Import from link'),
      content: TextField(
        controller: url,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          labelText: tr('URL'),
          hintText: tr('https://github.com/…/skills'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d, false),
          child: const T('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(d, true),
          child: const T('Import'),
        ),
      ],
    ),
  );
  // Not disposed here: the dialog still shows it while it closes.
  final text = url.text.trim();
  return ok == true && text.isNotEmpty ? text : null;
}
