import 'dart:async';

import '../../core/widgets/empty_state.dart';

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_extras.dart' show titleFromTask;
import '../chat/file_details.dart' show FileDetailsScreen;
import '../chat/formatting_toolbar.dart' show FormattingToolbar;
import '../studio/record_notes.dart' show dictate;
import '../studio/studio_export.dart' show pdfTheme, toPdf;
import '../workspace/access_editor.dart' show editAccess;
import 'notes_api.dart';
import '../../core/widgets/markdown_style.dart';
import '../../core/widgets/search_field.dart';
import '../../core/i18n/app_strings.dart';

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
            content: const T('This can\'t be undone.'),
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr(text))));
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
    return Scaffold(
      appBar: AppBar(
        title: const T('Notes'),
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: tr('New note'),
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
              child: SearchField(
                hint: 'Search notes',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load notes.\n$_error'),
              )
            else if (!_loading && shown.isEmpty)
              _query.isEmpty
                  ? const EmptyState(
                      icon: Icons.sticky_note_2_outlined,
                      title: 'No notes yet',
                      message: 'Tap the pencil to write one.',
                    )
                  : const EmptyState(
                      icon: Icons.search_off,
                      title: 'No notes match',
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
          const PopupMenuItem(value: 'delete', child: T('Delete')),
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
/// [v] with [said] put in where the cursor is (or over the selection, or
/// at the end), with a space before it when it would run into a word.
TextEditingValue insertSaid(TextEditingValue v, String said) {
  final at = v.selection.isValid ? v.selection.start : v.text.length;
  final end = v.selection.isValid ? v.selection.end : at;
  final before = v.text.substring(0, at);
  final gap = before.isEmpty || before.endsWith('\n') || before.endsWith(' ')
      ? ''
      : ' ';
  return TextEditingValue(
    text: '$before$gap$said${v.text.substring(end)}',
    selection: TextSelection.collapsed(offset: at + gap.length + said.length),
  );
}

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

  /// The web's Formatting switch: here, the bar of bold, lists and
  /// headings above the text (on, as the web starts).
  bool _formatting = true;
  final _history = UndoHistoryController();
  bool _enhancing = false;
  bool _loaded = false;
  bool _preview = false;
  bool _dirty = false;
  bool _saving = false;
  bool _uploading = false;
  List<Map<String, dynamic>> _files = const [];
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
      _files = n.files;
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
    if (mounted && !_closing) setState(() => _saving = true);
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr(text))));

  Future<void> _record() async {
    final said = (await dictate(context, ref.read(clientProvider)))?.trim();
    if (said == null || said.isEmpty || !mounted) return;
    _body.value = insertSaid(_body.value, said);
    _changed();
  }

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

  /// The web's note chat: chats that belong to this note (the model can
  /// read and rewrite it), with their Chat history to pick from.
  Future<void> _chat() async {
    await _save();
    if (!mounted) return;
    final open = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => NoteChatHistory(noteId: widget.id),
    );
    if (open == null || !mounted) return;
    if (open == ':attach') {
      ref.read(chatControllerProvider.notifier)
        ..newChat()
        ..attachReference({
          'type': 'note',
          'id': widget.id,
          'name': _name,
          'status': 'uploaded',
        });
    } else {
      await ref.read(chatControllerProvider.notifier).open(open);
    }
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  bool _titling = false;

  /// A short title from the note's text, as the web's Generate.
  Future<void> _generateTitle() async {
    final model = ref.read(chatControllerProvider).modelId;
    if (model == null || _body.text.trim().isEmpty) {
      _say(
        model == null
            ? 'Pick a model in a chat first'
            : 'Write something first',
      );
      return;
    }
    setState(() => _titling = true);
    try {
      final reply = await ref
          .read(clientProvider)
          .streamCompletion(
            model: model,
            messages: [
              {'role': 'user', 'content': noteTitlePrompt(_body.text)},
            ],
          )
          .join();
      final title = titleFromTask({
        'choices': [
          {
            'message': {'content': reply},
          },
        ],
      });
      if (title != null && mounted) {
        _title.text = title;
        _changed();
      }
    } catch (e) {
      if (mounted) _say('$e');
    }
    if (mounted) setState(() => _titling = false);
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
      case 'access':
        await editAccess(
          context,
          ref,
          kind: 'note',
          id: widget.id,
          name: _title.text.isEmpty ? 'Note' : _title.text,
        );
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
      case 'upload':
        await _upload();
      case 'chat':
        await _chat();
      case 'formatting':
        setState(() => _formatting = !_formatting);
      case 'enhance':
        await _enhance();
      default:
        await _download(v);
    }
  }

  /// Upload files: added to the note on the server, as on the web.
  Future<void> _upload() async {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    setState(() => _uploading = true);
    final client = ref.read(clientProvider);
    final added = <Map<String, dynamic>>[];
    for (final f in picked) {
      try {
        final bytes = await f.readAsBytes();
        if (bytes.isEmpty) {
          _say("${f.name} is empty, so it wasn't added.");
          continue;
        }
        added.add(noteFileItem(await client.uploadFile(bytes, f.name)));
      } catch (e) {
        if (mounted) _say("Couldn't upload ${f.name}: $e");
      }
    }
    if (added.isNotEmpty) await _setFiles([..._files, ...added]);
    if (mounted) setState(() => _uploading = false);
  }

  Future<void> _setFiles(List<Map<String, dynamic>> files) async {
    final before = _files;
    setState(() => _files = files);
    try {
      await widget.api.update(widget.id, files: files);
    } catch (e) {
      if (mounted) {
        setState(() => _files = before);
        _say("Couldn't save the files: $e");
      }
    }
  }

  /// Set while the page closes: the last save runs without redrawing.
  bool _closing = false;

  @override
  void dispose() {
    _closing = true;
    _save();
    _history.dispose();
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
          if (_enhancing || _uploading)
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
                tooltip: tr('Undo'),
                icon: const Icon(Icons.undo),
                onPressed: v.canUndo ? _history.undo : null,
              ),
            ),
            ValueListenableBuilder(
              valueListenable: _history,
              builder: (context, v, _) => IconButton(
                tooltip: tr('Redo'),
                icon: const Icon(Icons.redo),
                onPressed: v.canRedo ? _history.redo : null,
              ),
            ),
          ],
          // The web's Record: say it, and the words go in where you are.
          if (_loaded && !_preview)
            IconButton(
              tooltip: tr('Record'),
              icon: const Icon(Icons.mic_none),
              onPressed: _record,
            ),
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
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: 'formatting',
                  checked: _formatting,
                  child: const T('Formatting'),
                ),
                const PopupMenuItem(
                  value: 'enhance',
                  child: ListTile(
                    leading: Icon(Icons.auto_awesome),
                    title: T('Enhance with AI'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'chat',
                  child: ListTile(
                    leading: Icon(Icons.chat_bubble_outline),
                    title: T('Chat about this note'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'upload',
                  child: ListTile(
                    leading: Icon(Icons.cloud_upload_outlined),
                    title: T('Upload files'),
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'copy',
                  child: ListTile(
                    leading: Icon(Icons.copy),
                    title: T('Copy text'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'link',
                  child: ListTile(
                    leading: Icon(Icons.link),
                    title: T('Copy link'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'md',
                  child: ListTile(
                    leading: Icon(Icons.download_outlined),
                    title: T('Download Markdown (.md)'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'txt',
                  child: ListTile(
                    leading: Icon(Icons.download_outlined),
                    title: T('Download text (.txt)'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'pdf',
                  child: ListTile(
                    leading: Icon(Icons.picture_as_pdf_outlined),
                    title: T('Download PDF'),
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'access',
                  child: ListTile(
                    leading: Icon(Icons.lock_outline),
                    title: T('Access'),
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
                  decoration: InputDecoration(
                    hintText: tr('Title'),
                    border: InputBorder.none,
                    suffixIcon: _titling
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            tooltip: tr('Generate'),
                            icon: const Icon(Icons.auto_awesome_outlined),
                            onPressed: _generateTitle,
                          ),
                  ),
                ),
                if (_files.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final f in _files)
                          InputChip(
                            avatar: Icon(
                              f['type'] == 'image'
                                  ? Icons.image_outlined
                                  : Icons.description_outlined,
                              size: 18,
                            ),
                            label: Text(
                              '${f['name'] ?? 'File'}',
                              overflow: TextOverflow.ellipsis,
                            ),
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => FileDetailsScreen(
                                  fileId: '${f['id']}',
                                  name: '${f['name'] ?? 'File'}',
                                ),
                              ),
                            ),
                            deleteButtonTooltipMessage: 'Remove',
                            onDeleted: () => _setFiles([
                              for (final o in _files)
                                if (o['id'] != f['id']) o,
                            ]),
                          ),
                      ],
                    ),
                  ),
                if (_preview)
                  GestureDetector(
                    onDoubleTap: () => setState(() => _preview = false),
                    child: MarkdownBlock(
                      data: _body.text,
                      config: nexusMarkdown(context),
                    ),
                  )
                else ...[
                  if (_formatting && !_enhancing)
                    FormattingToolbar(controller: _body, onChanged: _changed),
                  TextField(
                    controller: _body,
                    undoController: _history,
                    readOnly: _enhancing,
                    onChanged: (_) => _changed(),
                    autofocus: _body.text.isEmpty,
                    maxLines: null,
                    minLines: 12,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: tr('Write in Markdown…'),
                      border: InputBorder.none,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

/// The web's note title task.
String noteTitlePrompt(String content) =>
    '''### Task:
Generate a concise title summarizing the content in the content's primary language.
### Guidelines:
- The title should clearly represent the main theme or subject of the content.
- Keep it short: 2-4 words is best.
- Do not use emojis, quotation marks, or special formatting.
- Write the title in the content's primary language.
- Prioritize accuracy over creativity.
- Your entire response must consist solely of the JSON object, without any introductory or concluding text.
### Output:
JSON format: { "title": "your concise title here" }
### Content:
<content>
$content
</content>''';

/// Chat history for a note's chats, as the web's note chat menu: New chat,
/// the chat open now marked Current, and More Options to delete one.
/// Pops with the chat to open, or ":attach" for a plain chat with the note.
class NoteChatHistory extends ConsumerStatefulWidget {
  const NoteChatHistory({super.key, required this.noteId});
  final String noteId;

  @override
  ConsumerState<NoteChatHistory> createState() => _NoteChatHistoryState();
}

class _NoteChatHistoryState extends ConsumerState<NoteChatHistory> {
  late Future<List<Map>> _chats = _load();
  bool _busy = false;

  Future<List<Map>> _load() async {
    final res = await ref
        .read(clientProvider)
        .send('GET', '/api/v1/notes/${widget.noteId}/chats');
    return [...((res as List?) ?? const []).whereType<Map>()]..sort(
      (a, b) => ((b['updated_at'] ?? 0) as num).compareTo(
        (a['updated_at'] ?? 0) as num,
      ),
    );
  }

  Future<void> _new() async {
    setState(() => _busy = true);
    try {
      final chat =
          await ref
                  .read(clientProvider)
                  .send('POST', '/api/v1/notes/${widget.noteId}/chat')
              as Map;
      if (mounted) Navigator.pop(context, '${chat['id']}');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _delete(String id) async {
    try {
      await ref.read(clientProvider).deleteChat(id);
      if (ref.read(chatControllerProvider).chat?.id == id) {
        ref.read(chatControllerProvider.notifier).newChat();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) setState(() => _chats = _load());
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(chatControllerProvider).chat?.id;
    final muted = context.nexus.muted;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: FutureBuilder(
          future: _chats,
          builder: (context, snap) {
            final chats = snap.data ?? const <Map>[];
            return ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: T(
                    'Chat history',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.edit_square),
                  title: const T('New chat'),
                  enabled: !_busy,
                  onTap: _new,
                ),
                if (snap.connectionState != ConnectionState.done)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator(),
                  )
                else if (snap.hasError)
                  ListTile(title: Text('${snap.error}'))
                else if (chats.isEmpty)
                  ListTile(
                    title: T('No chat history', style: TextStyle(color: muted)),
                  ),
                for (final c in chats)
                  ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: Text(
                      '${c['title'] ?? (c['chat'] as Map?)?['title'] ?? tr('Chat')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: c['id'] == current
                        ? T('Current', style: TextStyle(color: muted))
                        : null,
                    onTap: () => Navigator.pop(context, '${c['id']}'),
                    trailing: PopupMenuButton<String>(
                      tooltip: tr('More Options'),
                      onSelected: (_) => _delete('${c['id']}'),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'delete', child: T('Delete')),
                      ],
                    ),
                  ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.attach_file),
                  title: const T('Attach to a new chat'),
                  subtitle: T(
                    'A regular chat with this note as a file.',
                    style: TextStyle(color: muted),
                  ),
                  onTap: () => Navigator.pop(context, ':attach'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
