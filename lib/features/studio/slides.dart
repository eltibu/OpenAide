/// Presentations in the Studio: slides kept as Markdown, one `## ` heading
/// per slide, so the server (and Open WebUI's Notes) can read them too.
library;

import 'sheet.dart' show slidesMarker;

class Slide {
  Slide({this.title = '', this.body = '', this.notes = ''});

  String title;

  /// Markdown: usually a list of points, one per line.
  String body;

  /// What the speaker says; not shown on the slide.
  String notes;

  Slide copy() => Slide(title: title, body: body, notes: notes);

  String toMarkdown() => [
    '## ${title.trim()}'.trimRight(),
    if (body.trim().isNotEmpty) body.trim(),
    if (notes.trim().isNotEmpty) 'Notes: ${notes.trim()}',
  ].join('\n\n');
}

/// The slides as a Studio file: the marker, then each slide.
String slidesToMarkdown(List<Slide> slides) =>
    [slidesMarker, for (final s in slides) s.toMarkdown()].join('\n\n');

final _slideHeading = RegExp(r'^##(?!#)\s*(.*)$');
final _notes = RegExp(
  r'^\**(?:speaker )?notes\**:\**\s*(.*)$',
  caseSensitive: false,
);

/// Reads slides: each `## ` heading starts one. A line starting "Notes:"
/// begins its speaker notes. Text before the first slide is left out,
/// unless there are no headings at all.
List<Slide> slidesFromMarkdown(String markdown) {
  final slides = <Slide>[];
  Slide? current;
  final body = StringBuffer();
  final notes = StringBuffer();
  var inNotes = false;
  var fenced = false;
  void close() {
    final slide = current;
    if (slide != null) {
      slide
        ..body = body.toString().trim()
        ..notes = notes.toString().trim();
      slides.add(slide);
    }
    body.clear();
    notes.clear();
    inNotes = false;
  }

  final lines = markdown
      .replaceAll('\r\n', '\n')
      .replaceFirst(slidesMarker, '')
      .split('\n');
  final hasSlides = lines.any(_slideHeading.hasMatch);
  if (!hasSlides) current = Slide();
  for (final line in lines) {
    if (line.trimLeft().startsWith('```')) fenced = !fenced;
    final h = fenced ? null : _slideHeading.firstMatch(line);
    if (h != null) {
      close();
      current = Slide(title: h.group(1)!.trim());
      continue;
    }
    if (current == null) continue;
    final n = fenced || inNotes ? null : _notes.firstMatch(line.trim());
    if (n != null) {
      inNotes = true;
      notes.writeln(n.group(1));
    } else if (inNotes) {
      notes.writeln(line);
    } else {
      body.writeln(line);
    }
  }
  close();
  return [
    for (final s in slides)
      if (hasSlides || s.body.isNotEmpty || s.notes.isNotEmpty) s,
  ];
}

/// One point on a slide, with how deep it sits.
class Point {
  const Point(this.text, this.level, {this.bullet = true});
  final String text;
  final int level;

  /// False for a plain line (not a list item).
  final bool bullet;
}

final _item = RegExp(r'^(\s*)(?:[-*+•]|\d+[.)])\s+(.*)$');

/// The points of a slide's body: list items (indent makes them deeper)
/// and plain lines. Their text keeps its Markdown marks.
List<Point> slidePoints(String body) => [
  for (final line in body.split('\n'))
    if (line.trim().isNotEmpty)
      switch (_item.firstMatch(line)) {
        final m? => Point(
          m.group(2)!.trim(),
          (m.group(1)!.replaceAll('\t', '  ').length ~/ 2).clamp(0, 4),
        ),
        _ => Point(line.trim(), 0, bullet: false),
      },
];

/// Text without Markdown marks.
String plainText(String s, {bool trim = true}) {
  final t = s
      .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m.group(1)!)
      .replaceAllMapped(RegExp(r'__(.+?)__'), (m) => m.group(1)!)
      .replaceAllMapped(
        RegExp(r'(?<!\w)[*_](.+?)[*_](?!\w)'),
        (m) => m.group(1)!,
      )
      .replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1)!)
      .replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!)
      .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
      .replaceFirst(RegExp(r'^>\s*'), '');
  return trim ? t.trim() : t;
}

// ---- What the AI is asked ----

const slidesRule =
    'Write the presentation in Markdown: one "## " heading per slide (the '
    'slide title), then its points as a short "- " list (sub-points '
    'indented two spaces). Keep each slide to at most six short points. '
    'After the points you may add a line starting "Notes: " with what the '
    'speaker says. The first slide is the title slide: its title and one '
    'line under it as a subtitle.';

const presentationKinds = [
  'Presentation',
  'Lesson',
  'Training',
  'Pitch',
  'Report',
  'Workshop',
  'Talk',
];

const deckSuggestions = [
  'Add a slide at the end with a summary',
  'Add speaker notes to every slide',
  'Make it shorter',
  'Make the points shorter',
  'Add an agenda slide after the title',
  'Translate to Spanish',
  'Translate to English',
  'Fix spelling and grammar',
];

const slideSuggestions = [
  'Make the points shorter',
  'Add a point',
  'Add an example',
  'Write speaker notes',
  'Simplify the wording',
  'Fix spelling and grammar',
];

List<Map<String, String>> generateSlidesPrompt({
  required String kind,
  required String about,
  String language = '',
}) => [
  {
    'role': 'system',
    'content':
        'You make slide presentations. Answer with the slides only, no '
        'comments before or after them. $slidesRule',
  },
  {
    'role': 'user',
    'content': [
      'Make a ${kind.toLowerCase()}.',
      'What it is about: $about',
      if (language.trim().isNotEmpty) 'Write it in ${language.trim()}.',
    ].join('\n'),
  },
];

List<Map<String, String>> deckEditPrompt({
  required String title,
  required String markdown,
  required String instruction,
}) => [
  {
    'role': 'system',
    'content':
        'You edit slide presentations. Answer with the whole changed '
        'presentation only, no comments before or after it. Keep its '
        'language unless asked to translate. $slidesRule',
  },
  {
    'role': 'user',
    'content':
        'Presentation "$title":\n\n${markdown.replaceFirst(slidesMarker, '').trim()}'
        '\n\n---\nChange it like this: $instruction',
  },
];

List<Map<String, String>> slideEditPrompt({
  required String title,
  required String markdown,
  required Slide slide,
  required String instruction,
}) => [
  {
    'role': 'system',
    'content':
        'You edit one slide of a presentation. Answer with that slide only: '
        'one "## " heading (its title), its points as a "- " list, and if '
        'it has or needs them, a line starting "Notes: " with speaker '
        "notes. No comments before or after it. Keep the presentation's "
        'language unless asked to translate.',
  },
  {
    'role': 'user',
    'content':
        'The whole presentation "$title", for context:\n\n'
        '${markdown.replaceFirst(slidesMarker, '').trim()}\n\n---\n'
        'The slide to change:\n\n${slide.toMarkdown()}\n\n---\n'
        'Change that slide like this: $instruction',
  },
];
