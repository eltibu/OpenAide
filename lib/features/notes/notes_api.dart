import 'package:markdown/markdown.dart' as md;

import '../../core/api/openwebui_client.dart';

/// The server stores times in seconds, milliseconds or nanoseconds depending
/// on the table; this reads any of them.
DateTime fromServerTime(num t) {
  if (t > 1e17) return DateTime.fromMicrosecondsSinceEpoch(t ~/ 1000);
  if (t > 1e14) return DateTime.fromMicrosecondsSinceEpoch(t.toInt());
  if (t > 1e11) return DateTime.fromMillisecondsSinceEpoch(t.toInt());
  return DateTime.fromMillisecondsSinceEpoch((t * 1000).toInt());
}

class Note {
  const Note({
    required this.id,
    required this.title,
    required this.markdown,
    required this.pinned,
    required this.updated,
  });

  factory Note.fromJson(Map j) {
    final content = ((j['data'] as Map?)?['content'] as Map?) ?? const {};
    return Note(
      id: '${j['id']}',
      title: '${j['title'] ?? ''}',
      markdown: '${content['md'] ?? ''}',
      pinned: j['is_pinned'] == true,
      updated: fromServerTime((j['updated_at'] as num?) ?? 0),
    );
  }

  final String id;
  final String title;

  /// The note's text as Markdown (cut short in lists).
  final String markdown;
  final bool pinned;
  final DateTime updated;
}

class NotesApi {
  NotesApi(this.client);
  final OpenWebUiClient client;

  static const _base = '/api/v1/notes';

  Future<List<Note>> list() async {
    final res = await client.send('GET', '$_base/');
    return [
      for (final n in (res as List? ?? const []).whereType<Map>())
        Note.fromJson(n),
    ]..sort((a, b) => b.updated.compareTo(a.updated));
  }

  Future<Note> get(String id) async => Note.fromJson(
    await client.send('GET', '$_base/${Uri.encodeComponent(id)}') as Map,
  );

  /// The content as the web editor reads it: its rich-text form is dropped
  /// so the web shows the Markdown written here.
  static Map<String, dynamic> _content(String markdown) => {
    'content': {
      'json': null,
      'html': md.markdownToHtml(
        markdown,
        extensionSet: md.ExtensionSet.gitHubWeb,
      ),
      'md': markdown,
    },
  };

  Future<Note> create(String title, [String markdown = '']) async =>
      Note.fromJson(
        await client.send(
          'POST',
          '$_base/create',
          body: {'title': title, 'data': _content(markdown)},
        ) as Map,
      );

  Future<void> update(String id, {String? title, String? markdown}) =>
      client.send(
        'POST',
        '$_base/${Uri.encodeComponent(id)}/update',
        body: {
          'title': ?title,
          if (markdown != null) 'data': _content(markdown),
        },
      );

  Future<void> togglePin(String id) =>
      client.send('POST', '$_base/${Uri.encodeComponent(id)}/pin');

  Future<void> delete(String id) =>
      client.send('DELETE', '$_base/${Uri.encodeComponent(id)}/delete');
}
