/// Skills for models without a server: instructions the model reads only
/// when a task needs them (the same idea as Open WebUI's and Claude's
/// skills, SKILL.md with a name and description up top). Some come with
/// the app; you can add your own.
library;

import 'dart:convert';

import 'package:archive/archive.dart';

class Skill {
  const Skill({
    required this.id,
    required this.name,
    required this.description,
    required this.content,
    this.builtIn = false,
  });

  final String id;
  final String name;
  final String description;

  /// The instructions (SKILL.md without its header).
  final String content;
  final bool builtIn;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'content': content,
  };

  factory Skill.fromJson(Map json) => Skill(
    id: '${json['id']}',
    name: '${json['name'] ?? json['id']}',
    description: '${json['description'] ?? ''}',
    content: '${json['content'] ?? ''}',
  );

  /// As a SKILL.md file, for sharing.
  String get skillMd =>
      '---\nname: $name\ndescription: ${description.replaceAll('\n', ' ')}\n'
      '---\n\n$content\n';
}

/// An id from a name: "Meeting minutes" reads meeting-minutes.
String skillId(String name) {
  final id = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return id.isEmpty ? 'skill' : id;
}

/// A skill from a SKILL.md file's text; [fallbackName] when it has no
/// header.
Skill? parseSkillMd(String text, {String? fallbackName}) {
  var body = text.replaceAll('\r\n', '\n');
  String? name;
  String? description;
  final header = RegExp(r'^\s*---\n([\s\S]*?)\n---\n?').firstMatch(body);
  if (header != null) {
    body = body.substring(header.end);
    for (final line in header[1]!.split('\n')) {
      final m = RegExp(r'^(\w[\w-]*)\s*:\s*(.*)$').firstMatch(line);
      if (m == null) continue;
      final v = m[2]!.trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
      if (m[1] == 'name') name = v;
      if (m[1] == 'description') description = v;
    }
  }
  body = body.trim();
  name ??=
      fallbackName ??
      RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(body)?[1]?.trim();
  if (name == null || name.isEmpty || body.isEmpty) return null;
  return Skill(
    id: skillId(name),
    name: name,
    description: description ?? '',
    content: body,
  );
}

/// Skills in a picked file: a SKILL.md (or any .md), a .skill or .zip with
/// SKILL.md files inside, or a .json export.
List<Skill> skillsFromFile(String fileName, List<int> bytes) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.skill') || lower.endsWith('.zip')) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final out = <Skill>[];
    for (final f in archive.files) {
      if (!f.isFile || !f.name.toLowerCase().endsWith('skill.md')) continue;
      final parts = f.name.split('/');
      final folder = parts.length > 1 ? parts[parts.length - 2] : null;
      final s = parseSkillMd(
        utf8.decode(f.content, allowMalformed: true),
        fallbackName: folder,
      );
      if (s != null) out.add(s);
    }
    return out;
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  if (lower.endsWith('.json')) {
    final j = jsonDecode(text);
    return [
      for (final s in (j is List ? j : [j]).whereType<Map>())
        if ((s['content'] ?? s['body']) != null)
          Skill.fromJson({...s, 'content': s['content'] ?? s['body']}),
    ];
  }
  final s = parseSkillMd(
    text,
    fallbackName: fileName.replaceFirst(RegExp(r'\.(md|txt)$'), ''),
  );
  return s == null ? const [] : [s];
}

/// What the model is told about the skills it has.
String skillsInstructions(List<Skill> skills) =>
    '# Skills\n\n'
    'You have skills: instructions for certain kinds of tasks. When a '
    "request matches one, call load_skill with its name first and follow "
    'what it says.\n'
    '${[for (final s in skills) '- ${s.name}: ${s.description}'].join('\n')}';

/// The skills that come with the app.
const builtInSkills = [
  Skill(
    id: 'summarize',
    name: 'Summarize',
    builtIn: true,
    description:
        'Summarize an article, web page, document, chat or long text into '
        'the key points.',
    content: '''# Summarize

1. If you were given a link, read it with fetch_page first.
2. Start with one sentence that says what it is about and the main
   conclusion.
3. Then 3 to 7 bullet points with the key facts, numbers, names and
   decisions. Keep each to one line.
4. End with anything the reader must act on, if there is any.
5. Keep the original's meaning: no opinions, nothing added. Say so if the
   text was cut off or unclear.
Match the length to the source: a short text gets a short summary.''',
  ),
  Skill(
    id: 'write-email',
    name: 'Write an email',
    builtIn: true,
    description:
        'Draft or reply to an email or message in the right tone, ready to '
        'send.',
    content: '''# Write an email

1. Work out who it is to, what it must achieve, and the tone (warm,
   formal, firm, brief). Ask only if the goal is truly unclear.
2. Give a subject line, then the email.
3. Open with the point in the first two sentences. One idea per short
   paragraph. End with a clear next step or question.
4. Use the person's own details; never invent facts, dates or promises.
   Leave [brackets] for anything you don't know.
5. Plain words, no filler ("I hope this finds you well"), no em dashes.
After the draft, offer one shorter or more formal version only if useful.''',
  ),
  Skill(
    id: 'meeting-minutes',
    name: 'Meeting minutes',
    builtIn: true,
    description:
        'Turn a meeting transcript, recording notes or rough notes into '
        'clean minutes with decisions and action items.',
    content: '''# Meeting minutes

Write the minutes in this order:
1. **Meeting**: title, date and who was there (only if known).
2. **Summary**: two or three sentences.
3. **Decisions**: each decision made, one per bullet.
4. **Action items**: a checklist, each with an owner and a due date when
   they were said: `- [ ] Owner: task (due date)`.
5. **Open questions**: anything left unresolved.
Use the speakers' names as given. Don't invent owners or dates. Leave out
small talk. Offer to save the minutes with save_note when done.''',
  ),
  Skill(
    id: 'translate',
    name: 'Translate',
    builtIn: true,
    description:
        'Translate text between languages naturally, keeping tone and '
        'meaning.',
    content: '''# Translate

1. If the target language isn't stated, use the user's language (or
   English, translating into it from another language).
2. Translate the meaning and tone, not word by word. Keep names,
   numbers, formatting and line breaks.
3. Give only the translation, unless something can't be translated
   directly (an idiom, a pun): then add one short note after it.
4. For a single word or phrase, give the most common translation and, if
   it matters, one alternative with when to use it.''',
  ),
  Skill(
    id: 'plan-trip',
    name: 'Plan a trip',
    builtIn: true,
    description:
        'Plan a trip or outing: itinerary, travel times, places to see, '
        'eat and stay, with a rough budget.',
    content: '''# Plan a trip

1. Check what you know: where, dates or length, who's going, budget and
   interests. Ask at most one short question if the place or length is
   missing; otherwise assume sensibly and say so.
2. Use web_search for current opening hours, events, prices and travel
   times. Read the best results with fetch_page. Never invent prices.
3. Give a day-by-day plan: morning, afternoon, evening, with travel time
   between places. Keep it realistic: no more than 3 or 4 things a day.
4. Add where to eat and where to stay, with a price range.
5. End with a rough budget and a short packing or booking checklist.
Offer to put plans in the calendar with add_calendar_event.''',
  ),
  Skill(
    id: 'research',
    name: 'Research a question',
    builtIn: true,
    description:
        'Look something up properly on the web: compare sources and answer '
        'with links.',
    content: '''# Research a question

1. Search with web_search using 2 or 3 different phrasings if the first
   results are thin.
2. Read the 2 to 4 most relevant results with fetch_page. Prefer
   official and primary sources and recent dates.
3. Answer the question directly first, then the supporting details.
4. Cite each fact with its source as a markdown link.
5. If sources disagree or the answer is uncertain, say so plainly.''',
  ),
  Skill(
    id: 'explain',
    name: 'Explain simply',
    builtIn: true,
    description:
        'Explain a topic, word, idea or how something works in plain '
        'language, with an example.',
    content: '''# Explain simply

1. Start with a one-sentence answer anyone could understand.
2. Then explain in short paragraphs, building from what people already
   know. Define any technical word the first time you use it.
3. Give one concrete, everyday example or comparison.
4. If it helps, end with "In short:" and the key point in one line.
Adjust the depth to how the question was asked.''',
  ),
];
