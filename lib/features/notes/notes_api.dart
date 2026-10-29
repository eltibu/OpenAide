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

/// The note a link points at: the server's own `/notes/{id}` page (or that
/// path alone), else null.
String? noteIdIn(String url, String serverUrl) {
  final server = Uri.tryParse(serverUrl);
  final link = Uri.tryParse(url);
  if (server == null || link == null) return null;
  final at = server.resolveUri(link);
  if (link.hasScheme && at.origin != server.origin) return null;
  var path = at.path;
  final base = server.path.replaceAll(RegExp(r'/+$'), '');
  if (base.isNotEmpty && path.startsWith(base)) {
    path = path.substring(base.length);
  }
  return RegExp(r'^/notes/([^/]+)$').firstMatch(path)?.group(1);
}

class Note {
  const Note({
    required this.id,
    required this.title,
    required this.markdown,
    required this.pinned,
    required this.updated,
    this.files = const [],
  });

  factory Note.fromJson(Map j) {
    final content = ((j['data'] as Map?)?['content'] as Map?) ?? const {};
    return Note(
      id: '${j['id']}',
      title: '${j['title'] ?? ''}',
      markdown: '${content['md'] ?? ''}',
      pinned: j['is_pinned'] == true,
      updated: fromServerTime((j['updated_at'] as num?) ?? 0),
      files: [
        for (final f
            in ((j['data'] as Map?)?['files'] as List? ?? const [])
                .whereType<Map>())
          if (f['id'] != null) f.cast<String, dynamic>(),
      ],
    );
  }

  final String id;
  final String title;

  /// The note's text as Markdown (cut short in lists).
  final String markdown;
  final bool pinned;
  final DateTime updated;

  /// Files added to the note (Upload files), as the web keeps them.
  final List<Map<String, dynamic>> files;
}

/// How the web lists an uploaded [file] (the server's record) in a note.
Map<String, dynamic> noteFileItem(Map<String, dynamic> file) => {
  'type': '${file['meta']?['content_type'] ?? ''}'.startsWith('image/')
      ? 'image'
      : 'file',
  'file': file,
  'id': file['id'],
  'url': '${file['id']}',
  'name': file['filename'] ?? file['meta']?['name'] ?? 'File',
  'collection_name':
      file['meta']?['collection_name'] ?? file['collection_name'] ?? '',
  'status': 'uploaded',
  'size': file['meta']?['size'],
};

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

  /// Changes the title, the text and the files given; the rest stays.
  Future<void> update(
    String id, {
    String? title,
    String? markdown,
    List<Map<String, dynamic>>? files,
  }) => client.send(
    'POST',
    '$_base/${Uri.encodeComponent(id)}/update',
    body: {
      'title': ?title,
      if (markdown != null || files != null)
        'data': {
          if (markdown != null) ..._content(markdown),
          // The web clears the list with null when the last one goes.
          if (files != null) 'files': files.isEmpty ? null : files,
        },
    },
  );

  Future<void> togglePin(String id) =>
      client.send('POST', '$_base/${Uri.encodeComponent(id)}/pin');

  Future<void> delete(String id) =>
      client.send('DELETE', '$_base/${Uri.encodeComponent(id)}/delete');
}
