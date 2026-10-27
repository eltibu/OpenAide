/// The rest of the web UI's + menu: attach a web page, a note, a knowledge
/// base or a past chat to the next message. The server reads them when the
/// message is answered, as it does for the web.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../notes/notes_api.dart';
import '../workspace/knowledge_api.dart';
import 'chat_controller.dart';

/// One thing to pick.
typedef _Item = ({String id, String title, String subtitle});

/// Asks for a web address and attaches the page.
Future<void> attachWebpage(BuildContext context, WidgetRef ref) async {
  final text = TextEditingController();
  final url = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Attach a web page'),
      content: TextField(
        controller: text,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(hintText: 'https://…'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, text.text),
          child: const Text('Attach'),
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
  Future<List<_Item>> load(String query) async {
    switch (kind) {
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
        'note' => 'Attach a note',
        'collection' => 'Attach knowledge',
        _ => 'Attach a past chat',
      },
      load: load,
      // Chats are searched on the server; the others are filtered here.
      serverSearch: kind == 'chat',
    ),
  );
  if (picked == null) return;
  ref.read(chatControllerProvider.notifier).attachReference({
    'type': kind,
    'id': picked.id,
    'name': picked.title,
    if (kind == 'collection') 'description': picked.subtitle,
    'status': 'uploaded',
  });
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
                    decoration: const InputDecoration(
                      hintText: 'Search',
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
                      child: Text(
                        'Nothing here.',
                        style: TextStyle(color: muted),
                      ),
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
