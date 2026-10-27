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
import '../chat/chat_screen.dart' show readingInset;
import 'ai_sheet.dart';
import 'office.dart';
import 'record_notes.dart';
import 'sheet.dart';
import 'sheet_editor.dart';
import 'slides.dart';
import 'slides_editor.dart';
import 'studio_api.dart';
import 'studio_doc.dart';
import 'studio_export.dart';

final studioApiProvider = Provider<StudioApi>(
  (ref) => StudioApi(ref.watch(clientProvider)),
);

final studioDocsProvider = FutureProvider<List<StudioDocument>>(
  (ref) => ref.watch(studioApiProvider).list(),
);

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

String _when(BuildContext context, DateTime t) {
  final l = MaterialLocalizations.of(context);
  final now = DateTime.now();
  final today = t.year == now.year && t.month == now.month && t.day == now.day;
  return today
      ? l.formatTimeOfDay(TimeOfDay.fromDateTime(t))
      : '${l.formatMediumDate(t)}, ${l.formatTimeOfDay(TimeOfDay.fromDateTime(t))}';
}

/// The model the Studio writes with: the one picked in chat, else your
/// default.
String? studioModel(WidgetRef ref) {
  final picked = ref.read(chatControllerProvider).modelId;
  if (picked != null) return picked;
  final preferred = ref.read(defaultModelProvider).value;
  if (preferred != null) return preferred;
  final models = ref.read(modelsProvider).value ?? const [];
  return models.isEmpty ? null : models.first.id;
}

// ---- Library ----

/// The Studio: documents written and edited with AI help. They are kept on
/// the server as notes, so they are in Open WebUI's Notes too.
class StudioScreen extends ConsumerStatefulWidget {
  const StudioScreen({super.key});

  @override
  ConsumerState<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends ConsumerState<StudioScreen> {
  String _query = '';

  Future<void> _open(String id) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => StudioEditor(id: id)),
    );
    ref.invalidate(studioDocsProvider);
  }

  Future<void> _new() async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.mic_none),
              title: const Text('Record notes'),
              subtitle: const Text(
                'Meeting minutes, class notes or a dictated document',
              ),
              onTap: () => Navigator.pop(context, 'record'),
            ),
            for (final (k, icon, title, sub) in const [
              (
                'doc',
                Icons.description_outlined,
                'Document',
                'Letters, reports, lessons, notes (Word)',
              ),
              (
                'sheet',
                Icons.grid_on,
                'Spreadsheet',
                'Budgets, lists, grades, with formulas (Excel)',
              ),
              (
                'slides',
                Icons.slideshow_outlined,
                'Presentation',
                'Slides to show or share (PowerPoint)',
              ),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(title),
                subtitle: Text(sub),
                onTap: () => Navigator.pop(context, k),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('Open a file'),
              subtitle: const Text('Word, Excel, PowerPoint, CSV or text'),
              onTap: () => Navigator.pop(context, 'open'),
            ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;
    if (kind == 'open') return _openFile();
    if (kind == 'record') return _record();
    final noun = studioNoun(kind);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Make it with AI'),
              subtitle: Text('Say what it is, the AI makes a first $noun'),
              onTap: () => Navigator.pop(context, 'ai'),
            ),
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: Text('Blank $noun'),
              onTap: () => Navigator.pop(context, 'blank'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final api = ref.read(studioApiProvider);
    try {
      if (choice == 'blank') {
        final doc = await api.create('Untitled', switch (kind) {
          'sheet' => sheetsToMarkdown([Sheet(name: 'Sheet1')]),
          'slides' => slidesToMarkdown([Slide()]),
          _ => '',
        });
        await _open(doc.id);
        return;
      }
      final request = await showModalBottomSheet<Generate>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => GenerateSheet(kind: kind),
      );
      if (request == null || !mounted) return;
      final doc = await api.create(
        request.about.length > 60
            ? '${request.about.substring(0, 60)}…'
            : request.about,
        switch (kind) {
          'sheet' => sheetMarker,
          'slides' => slidesMarker,
          _ => '',
        },
      );
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => StudioEditor(id: doc.id, generate: request),
        ),
      );
      ref.invalidate(studioDocsProvider);
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  Future<void> _record() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const RecordNotesScreen()),
    );
    ref.invalidate(studioDocsProvider);
  }

  Future<void> _openFile() async {
    try {
      final files = await FilePicker.pickFiles();
      if (files.isEmpty || !mounted) return;
      final f = files.first;
      final (title, markdown) = importFile(f.name, await f.readAsBytes());
      final doc = await ref.read(studioApiProvider).create(title, markdown);
      if (mounted) await _open(doc.id);
    } catch (e) {
      if (mounted) _say(context, 'Couldn\'t open it: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(studioDocsProvider);
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Studio'),
        actions: [
          IconButton(
            tooltip: 'Record notes',
            onPressed: _record,
            icon: const Icon(Icons.mic_none),
          ),
          IconButton(
            tooltip: 'Open a file',
            onPressed: _openFile,
            icon: const Icon(Icons.file_open_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _new,
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              readingInset(context, 16),
              4,
              readingInset(context, 16),
              8,
            ),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search documents',
              ),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.refresh(studioDocsProvider.future),
              child: docs.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Couldn\'t load documents.\n$e'),
                    ),
                  ],
                ),
                data: (all) {
                  final items = [
                    for (final d in all)
                      if (_query.isEmpty ||
                          d.title.toLowerCase().contains(_query) ||
                          d.markdown.toLowerCase().contains(_query))
                        d,
                  ];
                  return ListView(
                    padding: EdgeInsets.fromLTRB(
                      readingInset(context, 8),
                      0,
                      readingInset(context, 8),
                      96,
                    ),
                    children: [
                      if (items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            all.isEmpty
                                ? 'Nothing here yet. Tap New for a document, '
                                      'spreadsheet or presentation, made by '
                                      'the AI or blank, or open a Word, Excel '
                                      'or PowerPoint file.'
                                : 'Nothing matches.',
                            style: TextStyle(color: muted),
                          ),
                        ),
                      for (final d in items)
                        ListTile(
                          leading: Icon(studioIcon(studioKind(d.markdown))),
                          title: Text(
                            d.title.isEmpty ? 'Untitled' : d.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              _when(context, d.updated),
                              d.markdown
                                  .replaceAll(sheetMarker, '')
                                  .replaceAll(slidesMarker, '')
                                  .replaceAll(RegExp(r'[#*_>`|-]'), ' ')
                                  .replaceAll(RegExp(r'\s+'), ' ')
                                  .trim(),
                            ].where((s) => s.isNotEmpty).join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: muted),
                          ),
                          onTap: () => _open(d.id),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

IconData studioIcon(String kind) => switch (kind) {
  'sheet' => Icons.grid_on,
  'slides' => Icons.slideshow_outlined,
  _ => Icons.description_outlined,
};

/// What a Studio file is called, in words.
String studioNoun(String kind) => switch (kind) {
  'sheet' => 'spreadsheet',
  'slides' => 'presentation',
  _ => 'document',
};

class Generate {
  const Generate(this.kind, this.about, this.language);
  final String kind;
  final String about;
  final String language;
}

class GenerateSheet extends StatefulWidget {
  const GenerateSheet({super.key, this.kind = 'doc'});

  /// doc, sheet or slides.
  final String kind;

  @override
  State<GenerateSheet> createState() => GenerateSheetState();
}

class GenerateSheetState extends State<GenerateSheet> {
  late final _kinds = switch (widget.kind) {
    'sheet' => sheetKinds,
    'slides' => presentationKinds,
    _ => documentKinds,
  };
  late String _kind = _kinds.first;
  final _about = TextEditingController();
  final _language = TextEditingController();

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      0,
      20,
      20 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Make a ${studioNoun(widget.kind)} with AI',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final k in _kinds)
              ChoiceChip(
                label: Text(k),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _about,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: 'What is it about?',
            hintText:
                'Who it is for, what it should cover, anything to include',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _language,
          decoration: const InputDecoration(
            labelText: 'Language (optional)',
            hintText: 'English, Spanish, both...',
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () {
            if (_about.text.trim().isEmpty) return;
            Navigator.pop(
              context,
              Generate(_kind, _about.text.trim(), _language.text.trim()),
            );
          },
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Make it'),
        ),
      ],
    ),
  );
}

// ---- Editor ----

class _Card {
  _Card(this.section)
    : head = TextEditingController(text: section.heading),
      body = TextEditingController(text: section.body);
  final Section section;
  final TextEditingController head;
  final TextEditingController body;
  final key = GlobalKey();

  Section get current =>
      Section(level: section.level, heading: head.text, body: body.text);

  void dispose() {
    head.dispose();
    body.dispose();
  }
}

/// One document: its sections as cards, each with big controls and its
/// own AI editing; the whole document can be changed by AI too. Every
/// change is saved on the server and kept as a version.
class StudioEditor extends ConsumerStatefulWidget {
  const StudioEditor({super.key, required this.id, this.generate});
  final String id;
  final Generate? generate;

  @override
  ConsumerState<StudioEditor> createState() => _StudioEditorState();
}

class _StudioEditorState extends ConsumerState<StudioEditor> {
  final _title = TextEditingController();
  final _cards = <_Card>[];
  List<Version> _versions = [];
  bool _loading = true;
  Object? _error;
  String? _model;
  Timer? _saveTimer;
  String _saved = '';
  String _savedTitle = '';
  bool _saving = false;

  /// Text the AI is writing for a new document, shown as it comes.
  String? _drafting;

  /// doc, sheet or slides. Sheets and slides are edited by their own
  /// editors, which hand up their whole text in [_body]; [_gen] makes a
  /// new editor when the text is replaced (AI, a restored version).
  String _kind = 'doc';
  String _body = '';
  int _gen = 0;

  /// Held from the start: the last save runs while the page closes.
  late final StudioApi _api;

  @override
  void initState() {
    super.initState();
    _api = ref.read(studioApiProvider);
    _model = studioModel(ref);
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // Whatever was typed last is kept.
    if (!_loading && _error == null) unawaited(_save());
    for (final c in _cards) {
      c.dispose();
    }
    super.dispose();
  }

  String get _markdown => _kind == 'doc'
      ? joinSections([for (final c in _cards) c.current])
      : _body;

  void _setContent(String markdown) {
    if (_kind == 'doc') {
      _setCards(markdown);
    } else {
      _body = markdown;
      _gen++;
    }
  }

  Future<void> _load() async {
    try {
      final doc = await _api.get(widget.id);
      if (!mounted) return;
      _title.text = doc.title;
      _savedTitle = doc.title;
      _saved = doc.markdown;
      _versions = [...doc.versions];
      _kind = studioKind(doc.markdown);
      _setContent(doc.markdown);
      setState(() => _loading = false);
      if (widget.generate != null) unawaited(_write(widget.generate!));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  void _setCards(String markdown) {
    for (final c in _cards) {
      c.dispose();
    }
    _cards
      ..clear()
      ..addAll([for (final s in splitSections(markdown)) _Card(s)]);
    if (_cards.isEmpty) _cards.add(_Card(Section(level: 0)));
  }

  void _changed() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1500), _save);
  }

  /// Saves; [label] marks a version of its own (AI changes, restores).
  /// Typing is folded into one version per two minutes.
  Future<void> _save({String? label}) async {
    _saveTimer?.cancel();
    final markdown = _markdown;
    final title = _title.text.trim().isEmpty ? 'Untitled' : _title.text.trim();
    if (markdown == _saved && title == _savedTitle && label == null) return;
    final now = DateTime.now();
    final last = _versions.isEmpty ? null : _versions.last;
    final version = Version(
      markdown: markdown,
      title: title,
      at: now,
      label: label ?? 'Typing',
    );
    if (label == null &&
        last != null &&
        last.label == 'Typing' &&
        now.difference(last.at) < const Duration(minutes: 2)) {
      _versions[_versions.length - 1] = version;
    } else {
      _versions.add(version);
    }
    _saved = markdown;
    _savedTitle = title;
    if (mounted) setState(() => _saving = true);
    try {
      await _api.save(
        widget.id,
        title: title,
        markdown: markdown,
        versions: _versions,
      );
    } catch (e) {
      // Kept on screen; the next change tries again.
      _saved = '';
      if (mounted) _say(context, 'Not saved: $e');
    }
    if (mounted) setState(() => _saving = false);
  }

  Stream<String> _ask(List<Map<String, String>> messages) {
    final model = _model;
    if (model == null) {
      return Stream.error('Pick a model first (⋮ > Model)');
    }
    return ref
        .read(clientProvider)
        .streamCompletion(model: model, messages: messages);
  }

  Future<void> _write(Generate g) async {
    setState(() => _drafting = '');
    var text = '';
    try {
      await for (final delta in _ask(switch (_kind) {
        'sheet' => generateSheetPrompt(
          kind: g.kind,
          about: g.about,
          language: g.language,
        ),
        'slides' => generateSlidesPrompt(
          kind: g.kind,
          about: g.about,
          language: g.language,
        ),
        _ => generatePrompt(kind: g.kind, about: g.about, language: g.language),
      })) {
        text += delta;
        if (mounted) setState(() => _drafting = text);
      }
      final (title, body) = _read(cleanAiText(text));
      if (!mounted) return;
      if (title.isNotEmpty) _title.text = title;
      _setContent(body);
      setState(() => _drafting = null);
      await _save(label: 'Made by AI');
    } catch (e) {
      if (!mounted) return;
      setState(() => _drafting = null);
      _say(context, 'The AI couldn\'t make it: $e');
    }
  }

  /// What the AI wrote, as this kind of file: its title (if it gave one)
  /// and its text.
  (String, String) _read(String text) {
    final (title, body) = titleAndBody(text);
    switch (_kind) {
      case 'sheet':
        final sheets = sheetsFromMarkdown(body);
        if (sheets.isEmpty) throw 'there was no table in its answer';
        return (title, sheetsToMarkdown(sheets));
      case 'slides':
        final slides = slidesFromMarkdown(text);
        if (slides.isEmpty) throw 'there were no slides in its answer';
        return (
          title.isEmpty ? plainText(slides.first.title) : title,
          slidesToMarkdown(slides),
        );
      default:
        return (title, title.isNotEmpty ? body : text);
    }
  }

  Future<void> _aiDocument() async {
    await _save();
    if (!mounted) return;
    final result = await showModalBottomSheet<AiResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AiSheet(
        dictate: (c) => dictate(c, ref.read(clientProvider)),
        title: 'Change the whole ${studioNoun(_kind)}',
        suggestions: switch (_kind) {
          'sheet' => sheetSuggestions,
          'slides' => deckSuggestions,
          _ => documentSuggestions,
        },
        run: (instruction) => _ask(
          (switch (_kind) {
            'sheet' => sheetEditPrompt,
            'slides' => deckEditPrompt,
            _ => documentEditPrompt,
          })(title: _title.text, markdown: _markdown, instruction: instruction),
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      final (_, body) = _read(cleanAiText(result.text));
      setState(() => _setContent(body));
    } catch (e) {
      _say(context, 'Not changed: $e');
      return;
    }
    await _save(label: 'AI: ${result.instruction}');
  }

  Future<void> _aiSection(_Card card) async {
    await _save();
    if (!mounted) return;
    final result = await showModalBottomSheet<AiResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AiSheet(
        dictate: (c) => dictate(c, ref.read(clientProvider)),
        title: card.head.text.isEmpty
            ? 'Change this part'
            : 'Change "${card.head.text}"',
        suggestions: sectionSuggestions,
        run: (instruction) => _ask(
          sectionEditPrompt(
            title: _title.text,
            markdown: _markdown,
            section: card.current,
            instruction: instruction,
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    var text = cleanAiText(result.text);
    // A heading the model repeated anyway is dropped.
    final head = card.head.text.trim();
    if (head.isNotEmpty) {
      text = text.replaceFirst(
        RegExp('^#{1,3}\\s+${RegExp.escape(head)}\\s*\\n+'),
        '',
      );
    }
    setState(() => card.body.text = text.trim());
    await _save(label: 'AI: ${result.instruction}');
  }

  /// Speech typed into [field] where the cursor is (or at the end).
  Future<void> _dictateInto(TextEditingController field) async {
    final said = await dictate(context, ref.read(clientProvider));
    if (said == null || said.isEmpty || !mounted) return;
    final text = field.text;
    final sel = field.selection;
    final at = sel.isValid ? sel.start.clamp(0, text.length) : text.length;
    final end = sel.isValid ? sel.end.clamp(at, text.length) : text.length;
    final before = text.substring(0, at);
    final gap = before.isEmpty || before.endsWith('\n') || before.endsWith(' ')
        ? ''
        : ' ';
    field.value = TextEditingValue(
      text: '$before$gap$said${text.substring(end)}',
      selection: TextSelection.collapsed(offset: at + gap.length + said.length),
    );
    setState(() {});
    _changed();
  }

  void _move(int i, int by) {
    final j = i + by;
    if (j < 0 || j >= _cards.length) return;
    setState(() {
      final c = _cards.removeAt(i);
      _cards.insert(j, c);
    });
    _changed();
  }

  void _addBelow(int i, {Section? copy}) {
    final card = _Card(copy ?? Section(level: 2, heading: 'New section'));
    setState(() => _cards.insert(i + 1, card));
    _changed();
    // Into view, ready to type.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = card.key.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
        );
      }
    });
  }

  Future<void> _remove(int i) async {
    final card = _cards[i];
    setState(() => _cards.removeAt(i));
    if (_cards.isEmpty) _cards.add(_Card(Section(level: 0)));
    _changed();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Section removed'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (!mounted) return;
            setState(() => _cards.insert(i.clamp(0, _cards.length), card));
            _changed();
          },
        ),
      ),
    );
  }

  Future<void> _export(String kind) async {
    await _save();
    final title = _title.text.trim().isEmpty ? 'Untitled' : _title.text.trim();
    final markdown = _markdown;
    try {
      final (Uint8List bytes, String type) = switch (kind) {
        'docx' => (
          toDocx(title, markdown),
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        ),
        'xlsx' => (
          toXlsx(sheetsFromMarkdown(markdown)),
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ),
        'csv' => (
          Uint8List.fromList(
            utf8.encode(toCsv(sheetsFromMarkdown(markdown).first)),
          ),
          'text/csv',
        ),
        'pptx' => (
          toPptx(title, slidesFromMarkdown(markdown)),
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        ),
        'pdf' => (
          _kind == 'slides'
              ? await slidesToPdf(
                  title,
                  slidesFromMarkdown(markdown),
                  theme: await pdfTheme(rootBundle.load),
                )
              : await toPdf(
                  title,
                  markdown,
                  theme: await pdfTheme(rootBundle.load),
                ),
          'application/pdf',
        ),
        _ => (
          Uint8List.fromList(
            utf8.encode(
              '# $title\n\n${markdown.replaceFirst(sheetMarker, '').replaceFirst(slidesMarker, '').trim()}\n',
            ),
          ),
          'text/markdown',
        ),
      };
      final name = exportName(title, kind);
      final saved = await FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        mimeType: type,
      );
      if (saved != null && mounted) _say(context, 'Saved $name');
    } catch (e) {
      if (mounted) _say(context, 'Couldn\'t export: $e');
    }
  }

  Future<void> _pickModel() async {
    final models = await ref.read(modelsProvider.future);
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final m in models)
              ListTile(
                title: Text(m.name),
                trailing: m.id == _model ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, m.id),
              ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => _model = picked);
  }

  Future<void> _showVersions() async {
    await _save();
    if (!mounted) return;
    final restore = await Navigator.push<Version>(
      context,
      MaterialPageRoute(
        builder: (_) => _VersionsScreen(versions: _versions.reversed.toList()),
      ),
    );
    if (restore == null || !mounted) return;
    _title.text = restore.title;
    setState(() => _setContent(restore.markdown));
    await _save(
      label: 'Restored the version from ${_when(context, restore.at)}',
    );
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete this ${studioNoun(_kind)}?'),
        content: const Text(
          'It is removed from the server, with its versions. Export it first '
          'if you may want it again.',
        ),
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
    try {
      _saveTimer?.cancel();
      await _api.delete(widget.id);
      _error = 'deleted';
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final models = ref.watch(modelsProvider).value ?? const [];
    _model ??= models.isEmpty ? null : models.first.id;
    final modelName =
        models.where((m) => m.id == _model).firstOrNull?.name ?? _model ?? '';
    final busy = _drafting != null;
    final titleField = TextField(
      controller: _title,
      enabled: !busy,
      style: Theme.of(context).textTheme.headlineSmall,
      decoration: const InputDecoration(
        hintText: 'Title',
        border: InputBorder.none,
      ),
      onChanged: (_) => _changed(),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _saving ? 'Saving…' : 'Studio',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        actions: [
          if (_kind == 'slides')
            IconButton(
              tooltip: 'Present',
              onPressed: _loading || busy
                  ? null
                  : () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => PresentScreen(
                          slides: slidesFromMarkdown(_markdown),
                        ),
                      ),
                    ),
              icon: const Icon(Icons.play_arrow_outlined),
            ),
          IconButton(
            tooltip: 'Versions',
            onPressed: _loading || busy ? null : _showVersions,
            icon: const Icon(Icons.history),
          ),
          PopupMenuButton<String>(
            enabled: !_loading && !busy,
            onSelected: (v) => switch (v) {
              'model' => _pickModel(),
              'delete' => _delete(),
              _ => _export(v),
            },
            itemBuilder: (_) => [
              ...switch (_kind) {
                'sheet' => const [
                  PopupMenuItem(value: 'xlsx', child: Text('Export to Excel')),
                  PopupMenuItem(
                    value: 'csv',
                    child: Text('Export CSV (first sheet)'),
                  ),
                ],
                'slides' => const [
                  PopupMenuItem(
                    value: 'pptx',
                    child: Text('Export to PowerPoint'),
                  ),
                  PopupMenuItem(value: 'pdf', child: Text('Export to PDF')),
                ],
                _ => const [
                  PopupMenuItem(value: 'docx', child: Text('Export to Word')),
                  PopupMenuItem(value: 'pdf', child: Text('Export to PDF')),
                ],
              },
              const PopupMenuItem(value: 'md', child: Text('Export Markdown')),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'model',
                child: Text('AI model: $modelName'),
              ),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      floatingActionButton: _loading || busy || _error != null
          ? null
          : FloatingActionButton.extended(
              onPressed: _aiDocument,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Edit all with AI'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Couldn\'t open this ${studioNoun(_kind)}.\n$_error'),
            )
          : _kind == 'sheet' && !busy
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: titleField,
                ),
                Expanded(
                  child: SheetEditor(
                    key: ValueKey(_gen),
                    markdown: _body,
                    onChanged: (md) {
                      _body = md;
                      _changed();
                    },
                  ),
                ),
              ],
            )
          : _kind == 'slides' && !busy
          ? SlidesEditor(
              key: ValueKey(_gen),
              markdown: _body,
              header: titleField,
              deckTitle: () => _title.text,
              ask: _ask,
              dictate: (c) => dictate(c, ref.read(clientProvider)),
              onChanged: (md, {label}) {
                _body = md;
                if (label != null) {
                  _save(label: label);
                } else {
                  _changed();
                }
              },
            )
          : ListView(
              padding: EdgeInsets.fromLTRB(
                readingInset(context, 12),
                8,
                readingInset(context, 12),
                120,
              ),
              children: [
                titleField,
                if (busy) ...[
                  Row(
                    children: [
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'The AI is making it…',
                        style: TextStyle(color: muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  MarkdownBlock(
                    data: _drafting!,
                    config: Theme.of(context).brightness == Brightness.dark
                        ? MarkdownConfig.darkConfig
                        : MarkdownConfig.defaultConfig,
                  ),
                ] else ...[
                  for (final (i, c) in _cards.indexed)
                    _SectionCard(
                      key: c.key,
                      card: c,
                      first: i == 0,
                      last: i == _cards.length - 1,
                      onChanged: _changed,
                      onAi: () => _aiSection(c),
                      onDictate: () => _dictateInto(c.body),
                      onUp: () => _move(i, -1),
                      onDown: () => _move(i, 1),
                      onCopy: () => _addBelow(i, copy: c.current),
                      onAdd: () => _addBelow(i),
                      onRemove: () => _remove(i),
                    ),
                ],
              ],
            ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    super.key,
    required this.card,
    required this.first,
    required this.last,
    required this.onChanged,
    required this.onAi,
    required this.onDictate,
    required this.onUp,
    required this.onDown,
    required this.onCopy,
    required this.onAdd,
    required this.onRemove,
  });
  final _Card card;
  final bool first;
  final bool last;
  final VoidCallback onChanged;
  final VoidCallback onAi;
  final VoidCallback onDictate;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final VoidCallback onCopy;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final level = card.section.level;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (level > 0)
              TextField(
                controller: card.head,
                onChanged: (_) => onChanged(),
                style:
                    (level == 1
                            ? text.titleLarge
                            : level == 2
                            ? text.titleMedium
                            : text.titleSmall)
                        ?.copyWith(fontWeight: FontWeight.w600),
                decoration: const InputDecoration(
                  hintText: 'Heading',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            TextField(
              controller: card.body,
              onChanged: (_) => onChanged(),
              maxLines: null,
              minLines: 2,
              style: text.bodyLarge,
              decoration: const InputDecoration(
                hintText: 'Write here',
                border: InputBorder.none,
                isDense: true,
              ),
            ),
            const SizedBox(height: 4),
            // Big controls, always there.
            Wrap(
              spacing: 0,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  onPressed: onAi,
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Edit with AI'),
                ),
                IconButton(
                  tooltip: 'Dictate',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDictate,
                  icon: const Icon(Icons.mic_none),
                ),
                IconButton(
                  tooltip: 'Move up',
                  visualDensity: VisualDensity.compact,
                  onPressed: first ? null : onUp,
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: 'Move down',
                  visualDensity: VisualDensity.compact,
                  onPressed: last ? null : onDown,
                  icon: const Icon(Icons.arrow_downward),
                ),
                IconButton(
                  tooltip: 'Duplicate',
                  visualDensity: VisualDensity.compact,
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_all_outlined),
                ),
                IconButton(
                  tooltip: 'Add a section below',
                  visualDensity: VisualDensity.compact,
                  onPressed: onAdd,
                  icon: const Icon(Icons.add_box_outlined),
                ),
                IconButton(
                  tooltip: 'Remove',
                  visualDensity: VisualDensity.compact,
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VersionsScreen extends StatelessWidget {
  const _VersionsScreen({required this.versions});

  /// Newest first.
  final List<Version> versions;

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(title: const Text('Versions')),
      body: ListView(
        children: [
          if (versions.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No versions yet. Each change you make is kept here.',
                style: TextStyle(color: muted),
              ),
            ),
          for (final (i, v) in versions.indexed)
            ListTile(
              leading: Icon(
                v.label.startsWith('AI') || v.label.contains('by AI')
                    ? Icons.auto_awesome
                    : Icons.edit_note,
              ),
              title: Text(
                v.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                i == 0 ? '${_when(context, v.at)} · now' : _when(context, v.at),
                style: TextStyle(color: muted),
              ),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(
                      title: Text(_when(context, v.at)),
                      actions: [
                        if (i > 0)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilledButton(
                              onPressed: () {
                                Navigator.pop(context);
                                Navigator.pop(context, v);
                              },
                              child: const Text('Restore'),
                            ),
                          ),
                      ],
                    ),
                    body: ListView(
                      padding: EdgeInsets.fromLTRB(
                        readingInset(context, 16),
                        8,
                        readingInset(context, 16),
                        40,
                      ),
                      children: [
                        Text(
                          v.title,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 12),
                        MarkdownBlock(
                          data: v.markdown,
                          config:
                              Theme.of(context).brightness == Brightness.dark
                              ? MarkdownConfig.darkConfig
                              : MarkdownConfig.defaultConfig,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
