/// The rest of the web UI's + menu: attach a web page, a note, a knowledge
/// base or a past chat to the next message. The server reads them when the
/// message is answered, as it does for the web.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/models/chat.dart' show Attachment;
import '../notes/notes_api.dart';
import '../workspace/knowledge_api.dart';
import '../workspace/knowledge_screen.dart' show knowledgeListProvider;
import 'chat_controller.dart';
import '../../core/i18n/app_strings.dart';

/// One thing to pick.
typedef _Item = ({String id, String title, String subtitle});

/// Asks for a web address and attaches the page.
Future<void> attachWebpage(BuildContext context, WidgetRef ref) async {
  final text = TextEditingController();
  final url = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const T('Attach a web page'),
      content: TextField(
        controller: text,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(hintText: tr('https://…')),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const T('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, text.text),
          child: const T('Attach'),
        ),
      ],
    ),
  );
  text.dispose();
  var u = (url ?? '').trim();
  if (u.isEmpty) return;
  if (!u.startsWith(RegExp('https?://'))) u = 'https://$u';
  await ref.read(chatControllerProvider.notifier).attachWebpage(u);
}

/// Picks one of your notes, knowledge bases or past chats ([kind] is
/// `note`, `collection` or `chat`) and attaches it.
Future<void> attachFromServer(
  BuildContext context,
  WidgetRef ref,
  String kind,
) async {
  final client = ref.read(clientProvider);
  final current = ref.read(chatControllerProvider).chat?.id;
  final files = <String, Map<String, dynamic>>{};
  Future<List<_Item>> load(String query) async {
    switch (kind) {
      case 'myfile':
        final found = await searchMyFiles(client, query);
        for (final f in found) {
          files['${f['id']}'] = f;
        }
        return [
          for (final f in found)
            (
              id: '${f['id']}',
              title: '${f['filename'] ?? (f['meta'] as Map?)?['name'] ?? ''}',
              subtitle: '${(f['meta'] as Map?)?['content_type'] ?? ''}',
            ),
        ];
      case 'note':
        return [
          for (final n in await NotesApi(client).list())
            (id: n.id, title: n.title, subtitle: _firstLine(n.markdown)),
        ];
      case 'collection':
        return [
          for (final k in await KnowledgeApi(client).list())
            (id: k.id, title: k.name, subtitle: k.description),
        ];
      default:
        final chats = query.trim().isEmpty
            ? await client.chats()
            : await client.searchChats(query.trim());
        return [
          for (final c in chats)
            if (c.id != current) (id: c.id, title: c.title, subtitle: ''),
        ];
    }
  }

  final picked = await showModalBottomSheet<_Item>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _Picker(
      title: switch (kind) {
        'myfile' => 'Attach one of your files',
        'note' => 'Attach a note',
        'collection' => 'Attach knowledge',
        _ => 'Attach a past chat',
      },
      load: load,
      // Chats are searched on the server; the others are filtered here.
      serverSearch: kind == 'chat' || kind == 'myfile',
    ),
  );
  if (picked == null) return;
  if (kind == 'myfile') {
    final f = files[picked.id];
    if (f != null) {
      ref.read(chatControllerProvider.notifier).attachReference(myFileEntry(f));
    }
    return;
  }
  ref.read(chatControllerProvider.notifier).attachReference({
    'type': kind,
    'id': picked.id,
    'name': picked.title,
    if (kind == 'collection') 'description': picked.subtitle,
    'status': 'uploaded',
  });
}

/// Your uploaded files whose names match [query], newest first, as the
/// web's Files picker searches them.
Future<List<Map<String, dynamic>>> searchMyFiles(
  OpenWebUiClient client,
  String query,
) async {
  final q = query.trim();
  final Object? res;
  try {
    res = await client.send(
      'GET',
      '/api/v1/files/search',
      query: {
        'filename': q.isEmpty
            ? '*'
            : RegExp(r'[?*]').hasMatch(q)
            ? q
            : '*$q*',
        'skip': '0',
        'limit': '50',
        'content': 'false',
      },
    );
  } on ApiException catch (e) {
    // The server answers 404 when nothing matches.
    if (e.statusCode == 404) return const [];
    rethrow;
  }
  final list = res is Map ? res['items'] ?? res['data'] : res;
  return [
    for (final f in list is List ? list : const [])
      if (f is Map) f.cast<String, dynamic>(),
  ];
}

/// A file already on the server, as the web adds it from the picker.
Map<String, dynamic> myFileEntry(Map<String, dynamic> f) {
  final type = '${(f['meta'] as Map?)?['content_type'] ?? ''}';
  final image = type.startsWith('image/') && !type.startsWith('image/svg');
  return {
    ...Attachment.uploaded(f).raw,
    if (image) 'type': 'image',
    'status': 'processed',
  };
}

/// Your notes, for "#" in the chat box.
final hashNotesProvider = FutureProvider.autoDispose<List<Note>>(
  (ref) => NotesApi(ref.watch(clientProvider)).list(),
);

/// What "#" offers, as on the web: a web address to attach, then your
/// knowledge bases and notes matching what follows it.
class HashMentions extends ConsumerWidget {
  const HashMentions({super.key, required this.query, required this.onDone});
  final String query;

  /// Something was attached; take the "#…" out of the text box.
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(chatControllerProvider.notifier);
    final q = query.toLowerCase();
    bool match(String a, String b) =>
        a.toLowerCase().contains(q) || b.toLowerCase().contains(q);
    final url = RegExp(r'^(https?://)?[\w-]+(\.[\w-]+)+(/\S*)?$')
        .hasMatch(query);
    final knowledge = ref.watch(knowledgeListProvider);
    final notes = ref.watch(hashNotesProvider);
    final tiles = <Widget>[
      if (url)
        ListTile(
          dense: true,
          leading: const Icon(Icons.language),
          title: Text('Attach $query'),
          subtitle: const T('Web page'),
          onTap: () {
            onDone();
            controller.attachWebpage(
              query.startsWith(RegExp('https?://')) ? query : 'https://$query',
            );
          },
        ),
      for (final k in knowledge.value ?? const <Knowledge>[])
        if (match(k.name, k.description))
          ListTile(
            dense: true,
            leading: const Icon(Icons.library_books_outlined),
            title: Text(k.name),
            subtitle: Text(
              k.description.isEmpty ? 'Knowledge' : k.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () {
              onDone();
              controller.attachReference({
                'type': 'collection',
                'id': k.id,
                'name': k.name,
                'description': k.description,
                'status': 'uploaded',
              });
            },
          ),
      for (final n in notes.value ?? const <Note>[])
        if (match(n.title, ''))
          ListTile(
            dense: true,
            leading: const Icon(Icons.sticky_note_2_outlined),
            title: Text(n.title.isEmpty ? 'Untitled note' : n.title),
            subtitle: const T('Note'),
            onTap: () {
              onDone();
              controller.attachReference({
                'type': 'note',
                'id': n.id,
                'name': n.title,
                'status': 'uploaded',
              });
            },
          ),
    ];
    if (tiles.isEmpty) {
      if (knowledge.isLoading || notes.isLoading) {
        return const LinearProgressIndicator(minHeight: 2);
      }
      return const SizedBox.shrink();
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(top: 6),
        children: tiles,
      ),
    );
  }
}

String _firstLine(String text) {
  final line = text
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'^[#>*\-\s]+'), '').trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  return line.length > 80 ? '${line.substring(0, 80)}…' : line;
}

class _Picker extends StatefulWidget {
  const _Picker({
    required this.title,
    required this.load,
    required this.serverSearch,
  });
  final String title;
  final Future<List<_Item>> Function(String query) load;
  final bool serverSearch;

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  late Future<List<_Item>> _items = widget.load('');
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    decoration: InputDecoration(
                      hintText: tr('Search'),
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.search,
                    onChanged: widget.serverSearch
                        ? null
                        : (v) => setState(() => _query = v),
                    onSubmitted: widget.serverSearch
                        ? (v) => setState(() => _items = widget.load(v))
                        : null,
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<_Item>>(
                future: _items,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text("Couldn't load them.\n\n${snap.error}"),
                    );
                  }
                  final q = _query.trim().toLowerCase();
                  final items = [
                    for (final i in snap.data!)
                      if (q.isEmpty ||
                          i.title.toLowerCase().contains(q) ||
                          i.subtitle.toLowerCase().contains(q))
                        i,
                  ];
                  if (items.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: T('Nothing here.', style: TextStyle(color: muted)),
                    );
                  }
                  return ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, i) => ListTile(
                      title: Text(
                        items[i].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: items[i].subtitle.isEmpty
                          ? null
                          : Text(
                              items[i].subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      onTap: () => Navigator.pop(context, items[i]),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
