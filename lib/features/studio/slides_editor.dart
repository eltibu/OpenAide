import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import 'ai_sheet.dart';
import 'slides.dart';
import 'studio_doc.dart' show cleanAiText;
import '../../core/i18n/app_strings.dart';

/// A slide drawn the way it is presented and exported: 16:9, title on
/// top (centred on the first slide), then its points.
class SlideView extends StatelessWidget {
  const SlideView({super.key, required this.slide, required this.index});
  final Slide slide;
  final int index;

  static TextSpan _spans(String text, TextStyle style) {
    // **bold** shows bold; other marks are taken off.
    final parts = text.split('**');
    return TextSpan(
      style: style,
      children: [
        for (var i = 0; i < parts.length; i++)
          if (parts[i].isNotEmpty)
            TextSpan(
              text: plainText(parts[i], trim: false),
              style: i.isOdd
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF1F1F1F);
    final points = slidePoints(slide.body);
    final title = plainText(slide.title);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: Colors.white,
        child: FittedBox(
          child: SizedBox(
            width: 960,
            height: 540,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(64, 44, 64, 28),
              child: index == 0
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 54,
                            color: ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 20),
                        for (final p in points)
                          Text.rich(
                            _spans(
                              p.text,
                              const TextStyle(
                                fontSize: 26,
                                color: Color(0xFF6B6B6B),
                              ),
                            ),
                            textAlign: TextAlign.center,
                          ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 42,
                            color: ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 22),
                        Expanded(
                          child: ClipRect(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final p in points)
                                  Padding(
                                    padding: EdgeInsets.only(
                                      left: p.level * 36.0,
                                      bottom: 12,
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (p.bullet)
                                          SizedBox(
                                            width: 30,
                                            child: Text(
                                              p.level == 0 ? '•' : '–',
                                              style: const TextStyle(
                                                fontSize: 28,
                                                color: ink,
                                              ),
                                            ),
                                          ),
                                        Expanded(
                                          child: Text.rich(
                                            _spans(
                                              p.text,
                                              TextStyle(
                                                fontSize: p.level == 0
                                                    ? 28
                                                    : 24,
                                                color: ink,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.bottomRight,
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              fontSize: 16,
                              color: Color(0xFF9E9E9E),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SlideCard {
  _SlideCard(Slide s)
    : title = TextEditingController(text: s.title),
      body = TextEditingController(text: s.body),
      notes = TextEditingController(text: s.notes),
      showNotes = s.notes.trim().isNotEmpty;
  final TextEditingController title;
  final TextEditingController body;
  final TextEditingController notes;
  bool showNotes;
  final key = GlobalKey();

  Slide get slide =>
      Slide(title: title.text, body: body.text, notes: notes.text);

  void dispose() {
    title.dispose();
    body.dispose();
    notes.dispose();
  }
}

/// A presentation: each slide as a card with its preview, its words and
/// notes, and its own AI editing.
class SlidesEditor extends StatefulWidget {
  const SlidesEditor({
    super.key,
    required this.markdown,
    required this.onChanged,
    required this.ask,
    required this.deckTitle,
    required this.header,
    this.dictate,
  });

  final String markdown;

  /// [label] marks a version of its own (AI changes).
  final void Function(String markdown, {String? label}) onChanged;
  final Stream<String> Function(List<Map<String, String>> messages) ask;
  final String Function() deckTitle;
  final Widget header;
  final Future<String?> Function(BuildContext context)? dictate;

  @override
  State<SlidesEditor> createState() => SlidesEditorState();
}

class SlidesEditorState extends State<SlidesEditor> {
  final _cards = <_SlideCard>[];

  @override
  void initState() {
    super.initState();
    final slides = slidesFromMarkdown(widget.markdown);
    _cards.addAll([
      for (final s in slides.isEmpty ? [Slide()] : slides) _SlideCard(s),
    ]);
  }

  @override
  void dispose() {
    for (final c in _cards) {
      c.dispose();
    }
    super.dispose();
  }

  List<Slide> get slides => [for (final c in _cards) c.slide];

  String get markdown => slidesToMarkdown(slides);

  void _changed({String? label}) {
    setState(() {});
    widget.onChanged(markdown, label: label);
  }

  void _move(int i, int by) {
    final j = i + by;
    if (j < 0 || j >= _cards.length) return;
    setState(() => _cards.insert(j, _cards.removeAt(i)));
    _changed();
  }

  void _addBelow(int i, {Slide? copy}) {
    final card = _SlideCard(copy ?? Slide(title: 'New slide', body: '- '));
    setState(() => _cards.insert(i + 1, card));
    _changed();
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

  void _remove(int i) {
    final card = _cards.removeAt(i);
    if (_cards.isEmpty) _cards.add(_SlideCard(Slide()));
    _changed();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const T('Slide removed'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (!mounted) return;
            _cards.insert(i.clamp(0, _cards.length), card);
            _changed();
          },
        ),
      ),
    );
  }

  Future<void> _ai(int i) async {
    final card = _cards[i];
    final result = await showModalBottomSheet<AiResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AiSheet(
        dictate: widget.dictate,
        title: card.title.text.trim().isEmpty
            ? 'Change slide ${i + 1}'
            : 'Change "${card.title.text.trim()}"',
        suggestions: slideSuggestions,
        run: (instruction) => widget.ask(
          slideEditPrompt(
            title: widget.deckTitle(),
            markdown: markdown,
            slide: card.slide,
            instruction: instruction,
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    final made = slidesFromMarkdown(cleanAiText(result.text));
    if (made.isEmpty) return;
    // One slide asked for; more than one back means the AI split it.
    final first = made.first;
    card
      ..title.text = first.title.isEmpty ? card.title.text : first.title
      ..body.text = first.body
      ..notes.text = first.notes;
    card.showNotes = card.notes.text.trim().isNotEmpty;
    for (final (k, extra) in made.skip(1).indexed) {
      _cards.insert(i + 1 + k, _SlideCard(extra));
    }
    _changed(label: 'AI: ${result.instruction}');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = context.nexus.muted;
    return ListView(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 120),
      children: [
        widget.header,
        for (final (i, c) in _cards.indexed)
          Card(
            key: c.key,
            elevation: 0,
            color: scheme.surfaceContainerLow,
            margin: const EdgeInsets.only(bottom: 14),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: DecoratedBox(
                        position: DecorationPosition.foreground,
                        decoration: BoxDecoration(
                          border: Border.all(color: scheme.outlineVariant),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SlideView(slide: c.slide, index: i),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    i == 0 ? 'Slide 1 · title slide' : 'Slide ${i + 1}',
                    style: text.labelMedium?.copyWith(color: muted),
                  ),
                  TextField(
                    controller: c.title,
                    onChanged: (_) => _changed(),
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      hintText: tr('Slide title'),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                  TextField(
                    controller: c.body,
                    onChanged: (_) => _changed(),
                    maxLines: null,
                    minLines: 2,
                    style: text.bodyLarge,
                    decoration: InputDecoration(
                      hintText: i == 0
                          ? 'Subtitle'
                          : '- One point per line\n  - indent for a sub-point',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                  if (c.showNotes)
                    TextField(
                      controller: c.notes,
                      onChanged: (_) => _changed(),
                      maxLines: null,
                      style: text.bodyMedium?.copyWith(color: muted),
                      decoration: InputDecoration(
                        labelText: tr('Speaker notes'),
                        isDense: true,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 4,
                    children: [
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        onPressed: () => _ai(i),
                        icon: const Icon(Icons.auto_awesome, size: 18),
                        label: const T('Edit with AI'),
                      ),
                      if (widget.dictate != null)
                        IconButton(
                          tooltip: tr('Dictate a point'),
                          visualDensity: VisualDensity.compact,
                          onPressed: () async {
                            final said = await widget.dictate!(context);
                            if (said == null || said.isEmpty || !mounted) {
                              return;
                            }
                            final body = c.body.text.trimRight();
                            c.body.text = i == 0
                                ? (body.isEmpty ? said : '$body\n$said')
                                : '${body.isEmpty || body == '-' ? '' : '$body\n'}- $said';
                            _changed();
                          },
                          icon: const Icon(Icons.mic_none),
                        ),
                      IconButton(
                        tooltip: c.showNotes ? 'Hide notes' : 'Speaker notes',
                        visualDensity: VisualDensity.compact,
                        onPressed: () =>
                            setState(() => c.showNotes = !c.showNotes),
                        icon: Icon(
                          c.showNotes
                              ? Icons.speaker_notes_off_outlined
                              : Icons.speaker_notes_outlined,
                        ),
                      ),
                      IconButton(
                        tooltip: tr('Move up'),
                        visualDensity: VisualDensity.compact,
                        onPressed: i == 0 ? null : () => _move(i, -1),
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      IconButton(
                        tooltip: tr('Move down'),
                        visualDensity: VisualDensity.compact,
                        onPressed: i == _cards.length - 1
                            ? null
                            : () => _move(i, 1),
                        icon: const Icon(Icons.arrow_downward),
                      ),
                      IconButton(
                        tooltip: tr('Duplicate'),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _addBelow(i, copy: c.slide),
                        icon: const Icon(Icons.copy_all_outlined),
                      ),
                      IconButton(
                        tooltip: tr('Add a slide below'),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _addBelow(i),
                        icon: const Icon(Icons.add_box_outlined),
                      ),
                      IconButton(
                        tooltip: tr('Remove'),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _remove(i),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The slides full screen, landscape: tap or swipe for the next one.
class PresentScreen extends StatefulWidget {
  const PresentScreen({super.key, required this.slides, this.start = 0});
  final List<Slide> slides;
  final int start;

  @override
  State<PresentScreen> createState() => _PresentScreenState();
}

class _PresentScreenState extends State<PresentScreen> {
  late final _pages = PageController(initialPage: widget.start);
  late int _at = widget.start;
  bool _notes = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([]);
    _pages.dispose();
    super.dispose();
  }

  void _go(int by) {
    final to = _at + by;
    if (to < 0 || to >= widget.slides.length) return;
    _pages.animateToPage(
      to,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final notes = widget.slides[_at].notes.trim();
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: widget.slides.length,
            onPageChanged: (i) => setState(() => _at = i),
            itemBuilder: (_, i) => GestureDetector(
              onTapUp: (d) => _go(
                d.localPosition.dx < MediaQuery.sizeOf(context).width / 3
                    ? -1
                    : 1,
              ),
              child: Center(
                child: SlideView(slide: widget.slides[i], index: i),
              ),
            ),
          ),
          if (_notes && notes.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  notes,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ),
          Positioned(
            top: 8,
            right: 8,
            child: Row(
              children: [
                Text(
                  '${_at + 1} / ${widget.slides.length}',
                  style: const TextStyle(color: Colors.white54),
                ),
                IconButton(
                  tooltip: _notes ? 'Hide notes' : 'Show notes',
                  color: Colors.white70,
                  onPressed: () => setState(() => _notes = !_notes),
                  icon: Icon(
                    _notes
                        ? Icons.speaker_notes_off_outlined
                        : Icons.speaker_notes_outlined,
                  ),
                ),
                IconButton(
                  tooltip: tr('Close'),
                  color: Colors.white70,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
