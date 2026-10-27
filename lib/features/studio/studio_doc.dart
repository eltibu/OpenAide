/// A document in the Studio: Markdown split into sections at its headings,
/// so each part can be edited, moved or rewritten on its own.
library;

class Section {
  Section({this.level = 2, this.heading = '', this.body = ''});

  /// 1 to 3 (`#` to `###`); 0 for the text before the first heading.
  int level;
  String heading;
  String body;

  Section copy() => Section(level: level, heading: heading, body: body);

  String toMarkdown() {
    final b = body.trim();
    if (level == 0 || heading.trim().isEmpty) return b;
    final head = '${'#' * level} ${heading.trim()}';
    return b.isEmpty ? head : '$head\n\n$b';
  }
}

final _heading = RegExp(r'^(#{1,3})\s+(.*)$');

/// Splits Markdown at its headings. Headings inside code blocks stay text.
List<Section> splitSections(String markdown) {
  final out = <Section>[];
  var current = Section(level: 0);
  final body = StringBuffer();
  var fenced = false;
  void close() {
    current.body = body.toString().trim();
    if (current.level != 0 || current.body.isNotEmpty) out.add(current);
    body.clear();
  }

  for (final line in markdown.replaceAll('\r\n', '\n').split('\n')) {
    if (line.trimLeft().startsWith('```')) fenced = !fenced;
    final m = fenced ? null : _heading.firstMatch(line);
    if (m != null) {
      close();
      current = Section(level: m.group(1)!.length, heading: m.group(2)!.trim());
    } else {
      body.writeln(line);
    }
  }
  close();
  return out;
}

String joinSections(List<Section> sections) => [
  for (final s in sections)
    if (s.toMarkdown().isNotEmpty) s.toMarkdown(),
].join('\n\n');

/// A saved state of a document, kept with it on the server.
class Version {
  const Version({
    required this.markdown,
    required this.title,
    required this.at,
    required this.label,
  });

  factory Version.fromJson(Map j) => Version(
    markdown: '${j['md'] ?? ''}',
    title: '${j['title'] ?? ''}',
    at: DateTime.fromMillisecondsSinceEpoch(
      ((j['at'] as num?) ?? 0).toInt() * 1000,
    ),
    label: '${j['label'] ?? ''}',
  );

  final String markdown;
  final String title;
  final DateTime at;

  /// What made it: "Typing", "AI: make it shorter", "Restored"...
  final String label;

  Map<String, dynamic> toJson() => {
    'md': markdown,
    'title': title,
    'at': at.millisecondsSinceEpoch ~/ 1000,
    'label': label,
  };
}

/// What a model wrote, without the code fence some models wrap it in.
String cleanAiText(String text) {
  var t = text.trim();
  final fence = RegExp(r'^```[a-zA-Z]*\n([\s\S]*?)\n?```$');
  final m = fence.firstMatch(t);
  if (m != null) t = m.group(1)!.trim();
  return t;
}

/// A new document's title from its first `# ` line, and the rest.
(String, String) titleAndBody(String markdown) {
  final lines = markdown.trim().split('\n');
  if (lines.isNotEmpty && RegExp(r'^#\s+').hasMatch(lines.first)) {
    return (
      lines.first.replaceFirst(RegExp(r'^#\s+'), '').trim(),
      lines.skip(1).join('\n').trim(),
    );
  }
  return ('', markdown.trim());
}

// ---- What the AI is asked ----

const layoutRule =
    'Write in Markdown. Separate paragraphs with an empty line and put each '
    'step or list item on its own line.';

/// Kinds of document "Write it with AI" offers.
const documentKinds = [
  'Document',
  'Letter',
  'Email',
  'Report',
  'Plan',
  'Lesson plan',
  'Quiz',
  'Handout',
  'Story',
  'Notes',
];

/// One-tap instructions for a whole document.
const documentSuggestions = [
  'Fix spelling and grammar',
  'Make it shorter',
  'Make it longer and more detailed',
  'Make it more formal',
  'Make it friendlier',
  'Translate to Spanish',
  'Translate to English',
  'Add a summary at the top',
];

/// One-tap instructions for a section.
const sectionSuggestions = [
  'Fix spelling and grammar',
  'Make it shorter',
  'Expand it',
  'Make it a bulleted list',
  'Add an example',
  'Simplify the wording',
];

List<Map<String, String>> generatePrompt({
  required String kind,
  required String about,
  String language = '',
}) => [
  {
    'role': 'system',
    'content':
        'You write documents. Answer with the document only, no comments '
        'before or after it. Start with one line "# Title". Use "## " '
        'headings for its sections. $layoutRule',
  },
  {
    'role': 'user',
    'content': [
      'Write a ${kind.toLowerCase()}.',
      'What it is about: $about',
      if (language.trim().isNotEmpty) 'Write it in ${language.trim()}.',
    ].join('\n'),
  },
];

List<Map<String, String>> documentEditPrompt({
  required String title,
  required String markdown,
  required String instruction,
}) => [
  {
    'role': 'system',
    'content':
        'You edit documents. Answer with the whole changed document only, '
        'no comments before or after it, and no title line. Keep its "## " '
        'section headings unless asked to change them. Keep its language '
        'unless asked to translate. $layoutRule',
  },
  {
    'role': 'user',
    'content':
        'Document "$title":\n\n$markdown\n\n---\nChange it like this: '
        '$instruction',
  },
];

List<Map<String, String>> sectionEditPrompt({
  required String title,
  required String markdown,
  required Section section,
  required String instruction,
}) => [
  {
    'role': 'system',
    'content':
        'You edit one part of a document. Answer with the new text of that '
        'part only: no heading line, no comments before or after it. Keep '
        "the document's language unless asked to translate. $layoutRule",
  },
  {
    'role': 'user',
    'content':
        'The whole document "$title", for context:\n\n$markdown\n\n---\n'
        'The part to change'
        '${section.heading.isEmpty ? '' : ' ("${section.heading}")'}:\n\n'
        '${section.body}\n\n---\nChange that part like this: $instruction',
  },
];
