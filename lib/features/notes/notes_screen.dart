import 'dart:async';

import '../../core/widgets/empty_state.dart';

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:uuid/uuid.dart';

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
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'\[[ xX]\]'), '')
        .replaceAll(RegExp(r'[#*_>`~\[\]-]'), '')
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
        [
          _ago(n.updated),
          if ((n.pageCount ?? 1) > 1) '${n.pageCount} ${tr('pages')}',
          if (snippet.isNotEmpty) snippet,
        ].join(' · '),
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
  const NoteEditorScreen({
    super.key,
    required this.api,
    required this.id,
    this.page,
  });
  final NotesApi api;
  final String id;

  /// The page to open (a link's ?page=), else the first.
  final String? page;

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

  /// The note's pages (Open WebUI 0.12.5+; empty before), the one open,
  /// and the revision page changes are checked against.
  List<NotePage> _pages = const [];
  String _pageId = 'main';
  int _pagesRevision = 0;
  bool _pageBusy = false;

  /// Who else has the note open, and on which page (live presence).
  List<Map<String, dynamic>> _people = const [];
  StreamSubscription<Map<String, dynamic>>? _presence;
  StreamSubscription<Map<String, dynamic>>? _noteEvents;

  bool get _paged => _pages.isNotEmpty;
  NotePage? get _page => _pages.where((p) => p.id == _pageId).firstOrNull;

  @override
  void initState() {
    super.initState();
    _load();
    _live();
  }

  Future<void> _load() async {
    try {
      final n = await widget.api.get(widget.id);
      _title.text = n.title;
      _pages = n.pages;
      _pagesRevision = n.pagesRevision;
      if (_paged) {
        _pageId = _pages.any((p) => p.id == widget.page)
            ? widget.page!
            : _pages.first.id;
        _body.text = _page!.markdown;
        _files = pageFiles(_body.text);
      } else {
        _body.text = n.markdown;
        _files = n.files;
      }
      _preview = _body.text.trim().isNotEmpty;
      _loaded = true;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  /// Joins the note's live room: who else is here, and page changes made
  /// elsewhere.
  void _live() {
    final socket = ref.read(chatSocketProvider);
    final me = ref.read(sessionProvider).value?.user?['id'];
    _presence = socket.notePresence.listen((e) {
      if (e['note_id'] != widget.id || !mounted) return;
      setState(
        () => _people = [
          for (final u in (e['users'] as List? ?? const []).whereType<Map>())
            if (u['id'] != me) u.cast<String, dynamic>(),
        ],
      );
    });
    _noteEvents = socket.noteEvents.listen((e) {
      if (e['id'] != widget.id || !mounted || _pageBusy) return;
      final data = e['data'];
      if (data is! Map || data['pages'] is! List) return;
      final rev = (data['pages_revision'] as num?)?.toInt() ?? 0;
      if (rev == _pagesRevision) return;
      final pages = [
        for (final p in (data['pages'] as List).whereType<Map>())
          NotePage.fromJson(p),
      ];
      setState(() {
        _pages = _withOpenText(pages);
        _pagesRevision = rev;
        if (_page == null) _show(_pages.first);
      });
    });
    socket.joinNote(widget.id);
  }

  /// [pages] from the server, keeping the open page's text as typed here.
  List<NotePage> _withOpenText(List<NotePage> pages) => [
    for (final p in pages)
      p.id == _pageId
          ? NotePage(
              id: p.id,
              title: p.title,
              markdown: _body.text,
              parentId: p.parentId,
              revision: p.revision,
            )
          : p,
  ];

  void _show(NotePage page) {
    _pageId = page.id;
    _body.text = page.markdown;
    _files = pageFiles(page.markdown);
    _history.value = UndoHistoryValue.empty;
    _preview = page.markdown.trim().isNotEmpty;
  }

  /// Opens another page, saving this one first.
  Future<void> _openPage(String id) async {
    if (id == _pageId || _pageBusy) return;
    await _save();
    final page = _pages.where((p) => p.id == id).firstOrNull;
    if (page == null || !mounted) return;
    setState(() => _show(page));
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
    final pageId = _paged ? _pageId : null;
    final text = _body.text;
    try {
      await widget.api.update(
        widget.id,
        title: _title.text.trim().isEmpty ? 'Untitled' : _title.text.trim(),
        markdown: text,
        pageId: pageId,
      );
      if (pageId != null) {
        _pages = [
          for (final p in _pages)
            p.id == pageId
                ? NotePage(
                    id: p.id,
                    title: p.title,
                    markdown: text,
                    parentId: p.parentId,
                    revision: p.revision + 1,
                  )
                : p,
        ];
      }
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

  /// Saves the note (the open page, with several) to the phone as
  /// Markdown, plain text or PDF.
  Future<void> _download(String kind) async {
    final page = _page;
    final name = page != null && _pages.length > 1 && !page.isMain
        ? '$_name - ${page.title}'
        : _name;
    try {
      final (Uint8List bytes, String type) = switch (kind) {
        'pdf' => (
          await toPdf(name, _body.text, theme: await pdfTheme(rootBundle.load)),
          'application/pdf',
        ),
        'md' => (
          Uint8List.fromList(utf8.encode('# $name\n\n${_body.text}')),
          'text/markdown',
        ),
        _ => (
          Uint8List.fromList(utf8.encode('$name\n\n${_body.text}')),
          'text/plain',
        ),
      };
      final file = '${name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.$kind';
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
            text:
                '${ref.read(clientProvider).baseUrl}/notes/${widget.id}'
                '${_paged ? '?page=${Uri.encodeComponent(_pageId)}' : ''}',
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
    if (added.isNotEmpty) {
      if (_paged) {
        // Since 0.12.5 a file sits inside the page it was added to.
        var text = _body.text;
        for (final f in added) {
          text = withFileLink(text, f);
        }
        _body.text = text;
        _files = pageFiles(text);
        _changed();
        await _save();
      } else {
        await _setFiles([..._files, ...added]);
      }
    }
    if (mounted) setState(() => _uploading = false);
  }

  Future<void> _setFiles(List<Map<String, dynamic>> files) async {
    if (_paged) {
      var text = _body.text;
      for (final f in _files) {
        if (!files.any((o) => o['id'] == f['id'])) {
          text = withoutFileLink(text, '${f['id']}');
        }
      }
      _body.text = text;
      setState(() => _files = pageFiles(text));
      _changed();
      return;
    }
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

  // ---- Pages (0.12.5) ----

  Future<String?> _pageTitle(String title, [String initial = '']) async {
    final text = TextEditingController(text: initial);
    final v = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: T(title),
        content: TextField(
          controller: text,
          autofocus: true,
          maxLength: 200,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: tr('Page title')),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, text.text),
            child: const T('Save'),
          ),
        ],
      ),
    );
    final t = v?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  /// A change to the pages, as the web's page tabs; opens [open] (or the
  /// new page) after.
  Future<void> _pageOp(
    String action, {
    String? pageId,
    String? parentId,
    bool toTop = false,
    String? beforeId,
    String? title,
  }) async {
    if (_pageBusy) return;
    setState(() => _pageBusy = true);
    await _save();
    final newId = action == 'create' || action == 'duplicate'
        ? const Uuid().v4()
        : null;
    try {
      final n = await widget.api.pages(
        widget.id,
        action,
        revision: _pagesRevision,
        pageId: pageId,
        newId: newId,
        parentId: parentId,
        toTop: toTop,
        beforeId: beforeId,
        title: title,
      );
      if (!mounted) return;
      final index = _pages.indexWhere((p) => p.id == _pageId);
      setState(() {
        _pages = _withOpenText(n.pages);
        _pagesRevision = n.pagesRevision;
        final target = newId != null
            ? _pages.where((p) => p.id == newId).firstOrNull
            : _page ?? _pages[index.clamp(0, _pages.length - 1)];
        if (target != null && target.id != _pageId) _show(target);
      });
    } catch (e) {
      if (mounted) _say('$e');
      // Someone else changed the pages: show them as they are now.
      try {
        final n = await widget.api.get(widget.id);
        if (mounted) {
          setState(() {
            _pages = _withOpenText(n.pages);
            _pagesRevision = n.pagesRevision;
          });
        }
      } catch (_) {}
    } finally {
      if (mounted) setState(() => _pageBusy = false);
    }
  }

  Future<void> _addPage({String? parentId}) async {
    final title = await _pageTitle(
      parentId == null ? 'New page' : 'New subpage',
    );
    if (title == null) return;
    await _pageOp('create', parentId: parentId, title: title);
  }

  /// The pages next to [page] under the same parent, in order.
  List<NotePage> _siblings(NotePage page) => [
    for (final p in _pages)
      if (p.parentId == page.parentId) p,
  ];

  Future<void> _pageMenu(NotePage page) async {
    final siblings = _siblings(page);
    final i = siblings.indexWhere((p) => p.id == page.id);
    final canUp = !page.isMain && i > 0 && !siblings[i - 1].isMain;
    final canDown = !page.isMain && i < siblings.length - 1;
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (s) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  page.title,
                  style: Theme.of(s).textTheme.titleMedium,
                ),
              ),
              for (final (value, icon, label, on) in [
                ('rename', Icons.edit_outlined, 'Rename', true),
                ('sub', Icons.subdirectory_arrow_right, 'Add subpage', true),
                ('duplicate', Icons.copy_all_outlined, 'Duplicate', true),
                ('up', Icons.arrow_upward, 'Move up', canUp),
                ('down', Icons.arrow_downward, 'Move down', canDown),
                (
                  'under',
                  Icons.drive_file_move_outline,
                  'Move under…',
                  !page.isMain,
                ),
                (
                  'top',
                  Icons.vertical_align_top,
                  'Move to top level',
                  !page.isMain && page.parentId != null,
                ),
                ('link', Icons.link, 'Copy link', true),
                ('md', Icons.download_outlined, 'Download page', true),
                (
                  'delete',
                  Icons.delete_outline,
                  'Delete',
                  !page.isMain && _pages.length > 1,
                ),
              ])
                if (on)
                  ListTile(
                    leading: Icon(icon),
                    title: T(label),
                    onTap: () => Navigator.pop(s, value),
                  ),
            ],
          ),
        ),
      ),
    );
    if (v == null || !mounted) return;
    switch (v) {
      case 'rename':
        final t = await _pageTitle('Rename page', page.title);
        if (t != null && t != page.title) {
          await _pageOp('rename', pageId: page.id, title: t);
        }
      case 'sub':
        await _addPage(parentId: page.id);
      case 'duplicate':
        await _pageOp('duplicate', pageId: page.id);
      case 'up':
        await _pageOp(
          'move',
          pageId: page.id,
          parentId: page.parentId,
          toTop: page.parentId == null,
          beforeId: siblings[i - 1].id,
        );
      case 'down':
        await _pageOp(
          'move',
          pageId: page.id,
          parentId: page.parentId,
          toTop: page.parentId == null,
          beforeId: i + 2 < siblings.length ? siblings[i + 2].id : null,
        );
      case 'top':
        await _pageOp('move', pageId: page.id, toTop: true);
      case 'under':
        final branch = pageBranch(_pages, page.id);
        final to = await showModalBottomSheet<String>(
          context: context,
          showDragHandle: true,
          builder: (s) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(title: T('Move "${page.title}" under')),
                for (final p in _pages)
                  if (!branch.contains(p.id) && p.id != page.parentId)
                    ListTile(
                      contentPadding: EdgeInsets.only(
                        left: 16.0 + 16 * pageDepth(_pages, p),
                        right: 16,
                      ),
                      leading: const Icon(Icons.description_outlined),
                      title: Text(p.title),
                      onTap: () => Navigator.pop(s, p.id),
                    ),
              ],
            ),
          ),
        );
        if (to != null) await _pageOp('move', pageId: page.id, parentId: to);
      case 'link':
        await Clipboard.setData(
          ClipboardData(
            text:
                '${ref.read(clientProvider).baseUrl}/notes/${widget.id}'
                '?page=${Uri.encodeComponent(page.id)}',
          ),
        );
        _say('Link copied');
      case 'md':
        if (page.id != _pageId) await _openPage(page.id);
        await _download('md');
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text('${tr('Delete page')} "${page.title}"?'),
            content: const T(
              'Its subpages move up a level. This can\'t be undone.',
            ),
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
        if (ok == true) await _pageOp('delete', pageId: page.id);
    }
  }

  /// The page tabs under the title: tap to open, hold for its menu.
  Widget _pageTabs() => SizedBox(
    height: 44,
    child: ListView(
      scrollDirection: Axis.horizontal,
      children: [
        for (final p in _pages)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onLongPress: () => _pageMenu(p),
              child: ChoiceChip(
                avatar: pageDepth(_pages, p) > 0
                    ? const Icon(Icons.subdirectory_arrow_right, size: 16)
                    : null,
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    '${'· ' * (pageDepth(_pages, p) > 1 ? pageDepth(_pages, p) - 1 : 0)}${p.title}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                selected: p.id == _pageId,
                onSelected: (_) =>
                    p.id == _pageId ? _pageMenu(p) : _openPage(p.id),
              ),
            ),
          ),
        IconButton(
          tooltip: tr('Add page'),
          icon: const Icon(Icons.add),
          onPressed: _pageBusy ? null : () => _addPage(),
        ),
      ],
    ),
  );

  /// Who else has the note open; tap one to go to their page.
  List<Widget> _presenceAvatars() => [
    for (final u in _people.take(4))
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Tooltip(
          message: [
            '${u['name'] ?? ''}',
            ?_pages.where((p) => p.id == u['page_id']).firstOrNull?.title,
          ].join(' · '),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: u['page_id'] is String
                ? () => _openPage(u['page_id'] as String)
                : null,
            child: CircleAvatar(
              radius: 14,
              child: Text(
                '${u['name'] ?? '?'}'.trim().isEmpty
                    ? '?'
                    : '${u['name']}'.trim()[0].toUpperCase(),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      ),
    if (_people.length > 4)
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Text('+${_people.length - 4}'),
      ),
  ];

  /// Set while the page closes: the last save runs without redrawing.
  bool _closing = false;

  @override
  void dispose() {
    _closing = true;
    _presence?.cancel();
    _noteEvents?.cancel();
    try {
      ref.read(chatSocketProvider).leaveNote(widget.id);
    } catch (_) {}
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
          ..._presenceAvatars(),
          if (_enhancing || _uploading || _pageBusy)
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
                // Pages and subpages (0.12.5): tap one, hold for its menu.
                if (_paged) _pageTabs(),
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
