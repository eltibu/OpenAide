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

/// The model the Studio writes with: the one picked in chat, else the first.
String? _defaultModel(WidgetRef ref) {
  final picked = ref.read(chatControllerProvider).modelId;
  if (picked != null) return picked;
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
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Write it with AI'),
              subtitle: const Text('Say what it is, the AI writes a draft'),
              onTap: () => Navigator.pop(context, 'ai'),
            ),
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: const Text('Blank document'),
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
        final doc = await api.create('Untitled', '');
        await _open(doc.id);
        return;
      }
      final request = await showModalBottomSheet<Generate>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => const GenerateSheet(),
      );
      if (request == null || !mounted) return;
      final doc = await api.create(
        request.about.length > 60
            ? '${request.about.substring(0, 60)}…'
            : request.about,
        '',
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

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(studioDocsProvider);
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(title: const Text('Studio')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _new,
        icon: const Icon(Icons.add),
        label: const Text('New document'),
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
                                ? 'No documents yet. Tap New document and let '
                                      'the AI write a first draft, or start '
                                      'blank.'
                                : 'Nothing matches.',
                            style: TextStyle(color: muted),
                          ),
                        ),
                      for (final d in items)
                        ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: Text(
                            d.title.isEmpty ? 'Untitled' : d.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              _when(context, d.updated),
                              d.markdown
                                  .replaceAll(RegExp(r'[#*_>`-]'), '')
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

class Generate {
  const Generate(this.kind, this.about, this.language);
  final String kind;
  final String about;
  final String language;
}

class GenerateSheet extends StatefulWidget {
  const GenerateSheet({super.key});

  @override
  State<GenerateSheet> createState() => GenerateSheetState();
}

class GenerateSheetState extends State<GenerateSheet> {
  String _kind = documentKinds.first;
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
        Text('Write it with AI', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final k in documentKinds)
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
          label: const Text('Write it'),
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

  /// Held from the start: the last save runs while the page closes.
  late final StudioApi _api;

  @override
  void initState() {
    super.initState();
    _api = ref.read(studioApiProvider);
    _model = _defaultModel(ref);
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

  String get _markdown => joinSections([for (final c in _cards) c.current]);

  Future<void> _load() async {
    try {
      final doc = await _api.get(widget.id);
      if (!mounted) return;
      _title.text = doc.title;
      _savedTitle = doc.title;
      _saved = doc.markdown;
      _versions = [...doc.versions];
      _setCards(doc.markdown);
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
      await for (final delta in _ask(
        generatePrompt(kind: g.kind, about: g.about, language: g.language),
      )) {
        text += delta;
        if (mounted) setState(() => _drafting = text);
      }
      final (title, body) = titleAndBody(cleanAiText(text));
      if (!mounted) return;
      if (title.isNotEmpty) _title.text = title;
      _setCards(body);
      setState(() => _drafting = null);
      await _save(label: 'Written by AI');
    } catch (e) {
      if (!mounted) return;
      setState(() => _drafting = null);
      _say(context, 'The AI couldn\'t write it: $e');
    }
  }

  Future<void> _aiDocument() async {
    await _save();
    if (!mounted) return;
    final result = await showModalBottomSheet<_AiResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AiSheet(
        title: 'Change the whole document',
        suggestions: documentSuggestions,
        run: (instruction) => _ask(
          documentEditPrompt(
            title: _title.text,
            markdown: _markdown,
            instruction: instruction,
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    final text = cleanAiText(result.text);
    final (title, body) = titleAndBody(text);
    setState(() => _setCards(title.isNotEmpty ? body : text));
    await _save(label: 'AI: ${result.instruction}');
  }

  Future<void> _aiSection(_Card card) async {
    await _save();
    if (!mounted) return;
    final result = await showModalBottomSheet<_AiResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AiSheet(
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
      final (Uint8List bytes, String name, String type) = switch (kind) {
        'docx' => (
          toDocx(title, markdown),
          exportName(title, 'docx'),
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        ),
        'pdf' => (
          await toPdf(title, markdown, theme: await pdfTheme(rootBundle.load)),
          exportName(title, 'pdf'),
          'application/pdf',
        ),
        _ => (
          Uint8List.fromList(utf8.encode('# $title\n\n$markdown\n')),
          exportName(title, 'md'),
          'text/markdown',
        ),
      };
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
    setState(() => _setCards(restore.markdown));
    await _save(
      label: 'Restored the version from ${_when(context, restore.at)}',
    );
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete this document?'),
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
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _saving ? 'Saving…' : 'Studio',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        actions: [
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
              const PopupMenuItem(value: 'docx', child: Text('Export to Word')),
              const PopupMenuItem(value: 'pdf', child: Text('Export to PDF')),
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
              child: Text('Couldn\'t open this document.\n$_error'),
            )
          : ListView(
              padding: EdgeInsets.fromLTRB(
                readingInset(context, 12),
                8,
                readingInset(context, 12),
                120,
              ),
              children: [
                TextField(
                  controller: _title,
                  enabled: !busy,
                  style: Theme.of(context).textTheme.headlineSmall,
                  decoration: const InputDecoration(
                    hintText: 'Title',
                    border: InputBorder.none,
                  ),
                  onChanged: (_) => _changed(),
                ),
                if (busy) ...[
                  Row(
                    children: [
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'The AI is writing…',
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

class _AiResult {
  const _AiResult(this.instruction, this.text);
  final String instruction;
  final String text;
}

/// Ask the AI for a change, watch it write, then keep it or not.
class _AiSheet extends StatefulWidget {
  const _AiSheet({
    required this.title,
    required this.suggestions,
    required this.run,
  });
  final String title;
  final List<String> suggestions;
  final Stream<String> Function(String instruction) run;

  @override
  State<_AiSheet> createState() => _AiSheetState();
}

class _AiSheetState extends State<_AiSheet> {
  final _instruction = TextEditingController();
  StreamSubscription<String>? _sub;
  String? _text;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _go([String? suggestion]) {
    if (suggestion != null) _instruction.text = suggestion;
    final instruction = _instruction.text.trim();
    if (instruction.isEmpty) {
      setState(() => _error = 'Say what to change, or tap a suggestion');
      return;
    }
    FocusScope.of(context).unfocus();
    _sub?.cancel();
    setState(() {
      _text = '';
      _error = null;
      _done = false;
    });
    _sub = widget
        .run(instruction)
        .listen(
          (d) => setState(() => _text = (_text ?? '') + d),
          onError: (Object e) => setState(() {
            _error = '$e';
            _done = true;
          }),
          onDone: () => setState(() => _done = true),
          cancelOnError: true,
        );
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final writing = _text != null && !_done;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _instruction,
              autofocus: _text == null,
              minLines: 1,
              maxLines: 4,
              enabled: !writing,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _go(),
              decoration: InputDecoration(
                hintText: 'What should change?',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Apply',
                  onPressed: writing ? null : _go,
                  icon: const Icon(Icons.send),
                ),
              ),
            ),
            if (_text == null) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final s in widget.suggestions)
                    ActionChip(label: Text(s), onPressed: () => _go(s)),
                ],
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_text != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (writing) ...[
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    writing ? 'Writing…' : 'The change',
                    style: TextStyle(color: muted),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Flexible(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: SingleChildScrollView(
                    reverse: writing,
                    child: MarkdownBlock(
                      data: cleanAiText(_text!),
                      config: Theme.of(context).brightness == Brightness.dark
                          ? MarkdownConfig.darkConfig
                          : MarkdownConfig.defaultConfig,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Discard'),
                  ),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: writing ? null : _go,
                    child: const Text('Try again'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: writing || _text!.trim().isEmpty
                        ? null
                        : () => Navigator.pop(
                            context,
                            _AiResult(_instruction.text.trim(), _text!),
                          ),
                    child: const Text('Keep it'),
                  ),
                ],
              ),
            ],
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
