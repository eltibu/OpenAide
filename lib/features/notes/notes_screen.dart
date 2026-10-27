import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import '../studio/studio_export.dart' show pdfTheme, toPdf;
import 'notes_api.dart';

/// The server's notes, native: search, pin, write in Markdown.
class NotesScreen extends ConsumerStatefulWidget {
  const NotesScreen({super.key});

  @override
  ConsumerState<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends ConsumerState<NotesScreen> {
  late final NotesApi _api = NotesApi(ref.read(clientProvider));
  List<Note> _notes = const [];
  String _query = '';
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _notes = await _api.list();
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(Note? note) async {
    var target = note;
    if (target == null) {
      try {
        final now = DateTime.now();
        final title =
            '${now.year}-${'${now.month}'.padLeft(2, '0')}-${'${now.day}'.padLeft(2, '0')}';
        target = await _api.create(title);
      } catch (e) {
        _say('$e');
        return;
      }
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => NoteEditorScreen(api: _api, id: target!.id),
      ),
    );
    _load();
  }

  Future<void> _act(Note n, String action) async {
    try {
      if (action == 'pin') await _api.togglePin(n.id);
      if (action == 'delete') {
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text('Delete "${n.title}"?'),
            content: const Text('This can\'t be undone.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(d, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        await _api.delete(n.id);
      }
    } catch (e) {
      _say('$e');
    }
    _load();
  }

  void _say(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final shown = [
      for (final n in _notes)
        if (q.isEmpty ||
            n.title.toLowerCase().contains(q) ||
            n.markdown.toLowerCase().contains(q))
          n,
    ];
    final pinned = shown.where((n) => n.pinned).toList();
    final rest = shown.where((n) => !n.pinned).toList();
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notes'),
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New note',
        onPressed: () => _open(null),
        child: const Icon(Icons.edit_outlined),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SearchBar(
                hintText: 'Search notes',
                leading: const Icon(Icons.search),
                elevation: const WidgetStatePropertyAll(0),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load notes.\n$_error'),
              )
            else if (!_loading && shown.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _query.isEmpty ? 'No notes yet' : 'No notes match',
                  style: TextStyle(color: muted),
                ),
              ),
            if (pinned.isNotEmpty) _Heading('Pinned'),
            for (final n in pinned) _tile(n),
            if (pinned.isNotEmpty && rest.isNotEmpty) _Heading('Notes'),
            for (final n in rest) _tile(n),
          ],
        ),
      ),
    );
  }

  Widget _tile(Note n) {
    final muted = context.nexus.muted;
    final snippet = n.markdown
        .replaceAll(RegExp(r'\[[ xX]\]'), '')
        .replaceAll(RegExp(r'[#*_>`\[\]-]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 20, right: 4),
      title: Text(
        n.title.isEmpty ? 'Untitled' : n.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [_ago(n.updated), if (snippet.isNotEmpty) snippet].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: muted),
      ),
      onTap: () => _open(n),
      trailing: PopupMenuButton<String>(
        onSelected: (a) => _act(n, a),
        itemBuilder: (_) => [
          PopupMenuItem(value: 'pin', child: Text(n.pinned ? 'Unpin' : 'Pin')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    if (d.inDays < 7) return '${d.inDays} d ago';
    return MaterialLocalizations.of(context).formatMediumDate(t);
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
    child: Text(
      text,
      style: TextStyle(color: context.nexus.muted, fontSize: 13),
    ),
  );
}

/// One note, written in Markdown and saved as you type, with a preview.
class NoteEditorScreen extends ConsumerStatefulWidget {
  const NoteEditorScreen({super.key, required this.api, required this.id});
  final NotesApi api;
  final String id;

  @override
  ConsumerState<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends ConsumerState<NoteEditorScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _history = UndoHistoryController();
  bool _enhancing = false;
  bool _loaded = false;
  bool _preview = false;
  bool _dirty = false;
  bool _saving = false;
  Object? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final n = await widget.api.get(widget.id);
      _title.text = n.title;
      _body.text = n.markdown;
      _preview = n.markdown.trim().isNotEmpty;
      _loaded = true;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  void _changed() {
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1200), _save);
    setState(() {});
  }

  Future<void> _save() async {
    _debounce?.cancel();
    if (!_dirty || !_loaded) return;
    _dirty = false;
    if (mounted) setState(() => _saving = true);
    try {
      await widget.api.update(
        widget.id,
        title: _title.text.trim().isEmpty ? 'Untitled' : _title.text.trim(),
        markdown: _body.text,
      );
    } catch (e) {
      _dirty = true;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Not saved: $e')));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  String get _name =>
      _title.text.trim().isEmpty ? 'Untitled' : _title.text.trim();

  /// Saves the note to the phone as Markdown, plain text or PDF.
  Future<void> _download(String kind) async {
    try {
      final (Uint8List bytes, String type) = switch (kind) {
        'pdf' => (
          await toPdf(
            _name,
            _body.text,
            theme: await pdfTheme(rootBundle.load),
          ),
          'application/pdf',
        ),
        'md' => (
          Uint8List.fromList(utf8.encode('# $_name\n\n${_body.text}')),
          'text/markdown',
        ),
        _ => (
          Uint8List.fromList(utf8.encode('$_name\n\n${_body.text}')),
          'text/plain',
        ),
      };
      final file = '${_name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.$kind';
      final saved = await FilePicker.saveFile(
        fileName: file,
        bytes: bytes,
        mimeType: type,
      );
      if (saved != null && mounted) _say('Saved $file');
    } catch (e) {
      if (mounted) _say("Couldn't save: $e");
    }
  }

  /// Opens a new chat with this note attached, as the web's Chat button.
  Future<void> _chat() async {
    await _save();
    if (!mounted) return;
    ref.read(chatControllerProvider.notifier)
      ..newChat()
      ..attachReference({
        'type': 'note',
        'id': widget.id,
        'name': _name,
        'status': 'uploaded',
      });
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// Rewrites the note with the chat's model (the web's Enhance); Undo
  /// brings the old text back.
  Future<void> _enhance() async {
    final model = ref.read(chatControllerProvider).modelId;
    if (model == null || _body.text.trim().isEmpty) {
      _say(
        model == null
            ? 'Pick a model in a chat first'
            : 'Write something first',
      );
      return;
    }
    setState(() {
      _enhancing = true;
      _preview = false;
    });
    final before = _body.text;
    var out = '';
    try {
      await for (final piece
          in ref
              .read(clientProvider)
              .streamCompletion(
                model: model,
                messages: [
                  {
                    'role': 'system',
                    'content':
                        'Enhance this note and update it: fix spelling and grammar, '
                        'organise it with Markdown headings and lists, keep every '
                        'fact. Reply with only the new note in Markdown.',
                  },
                  {'role': 'user', 'content': before},
                ],
              )) {
        out += piece;
        if (!mounted) return;
        _body.value = TextEditingValue(
          text: out,
          selection: TextSelection.collapsed(offset: out.length),
        );
      }
      if (out.trim().isEmpty) {
        _body.text = before;
      } else {
        _changed();
      }
    } catch (e) {
      _body.text = before;
      if (mounted) _say("Couldn't enhance: $e");
    }
    if (mounted) setState(() => _enhancing = false);
  }

  Future<void> _menu(String v) async {
    switch (v) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: _body.text));
        _say('Note copied');
      case 'link':
        await Clipboard.setData(
          ClipboardData(
            text: '${ref.read(clientProvider).baseUrl}/notes/${widget.id}',
          ),
        );
        _say('Link copied');
      case 'chat':
        await _chat();
      case 'enhance':
        await _enhance();
      default:
        await _download(v);
    }
  }

  @override
  void dispose() {
    _save();
    _history.dispose();
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _saving
              ? 'Saving…'
              : _dirty
              ? 'Edited'
              : 'Saved',
          style: TextStyle(color: muted, fontSize: 14),
        ),
        actions: [
          if (_enhancing)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (!_preview && _loaded) ...[
            ValueListenableBuilder(
              valueListenable: _history,
              builder: (context, v, _) => IconButton(
                tooltip: 'Undo',
                icon: const Icon(Icons.undo),
                onPressed: v.canUndo ? _history.undo : null,
              ),
            ),
            ValueListenableBuilder(
              valueListenable: _history,
              builder: (context, v, _) => IconButton(
                tooltip: 'Redo',
                icon: const Icon(Icons.redo),
                onPressed: v.canRedo ? _history.redo : null,
              ),
            ),
          ],
          IconButton(
            tooltip: _preview ? 'Edit' : 'Preview',
            isSelected: _preview,
            onPressed: _loaded
                ? () => setState(() => _preview = !_preview)
                : null,
            icon: Icon(
              _preview ? Icons.edit_outlined : Icons.visibility_outlined,
            ),
          ),
          if (_loaded)
            PopupMenuButton<String>(
              onSelected: _menu,
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'enhance',
                  child: ListTile(
                    leading: Icon(Icons.auto_awesome),
                    title: Text('Enhance with AI'),
                  ),
                ),
                PopupMenuItem(
                  value: 'chat',
                  child: ListTile(
                    leading: Icon(Icons.chat_bubble_outline),
                    title: Text('Chat about this note'),
                  ),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'copy',
                  child: ListTile(
                    leading: Icon(Icons.copy),
                    title: Text('Copy text'),
                  ),
                ),
                PopupMenuItem(
                  value: 'link',
                  child: ListTile(
                    leading: Icon(Icons.link),
                    title: Text('Copy link'),
                  ),
                ),
                PopupMenuItem(
                  value: 'md',
                  child: ListTile(
                    leading: Icon(Icons.download_outlined),
                    title: Text('Download Markdown (.md)'),
                  ),
                ),
                PopupMenuItem(
                  value: 'txt',
                  child: ListTile(
                    leading: Icon(Icons.download_outlined),
                    title: Text('Download text (.txt)'),
                  ),
                ),
                PopupMenuItem(
                  value: 'pdf',
                  child: ListTile(
                    leading: Icon(Icons.picture_as_pdf_outlined),
                    title: Text('Download PDF'),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Couldn\'t open the note.\n$_error'))
          : !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
              children: [
                TextField(
                  controller: _title,
                  onChanged: (_) => _changed(),
                  // Long titles wrap instead of running off the screen.
                  minLines: 1,
                  maxLines: 3,
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.done,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Title',
                    border: InputBorder.none,
                  ),
                ),
                if (_preview)
                  GestureDetector(
                    onDoubleTap: () => setState(() => _preview = false),
                    child: MarkdownBlock(
                      data: _body.text,
                      config: dark
                          ? MarkdownConfig.darkConfig
                          : MarkdownConfig.defaultConfig,
                    ),
                  )
                else
                  TextField(
                    controller: _body,
                    undoController: _history,
                    readOnly: _enhancing,
                    onChanged: (_) => _changed(),
                    autofocus: _body.text.isEmpty,
                    maxLines: null,
                    minLines: 12,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Write in Markdown…',
                      border: InputBorder.none,
                    ),
                  ),
              ],
            ),
    );
  }
}
