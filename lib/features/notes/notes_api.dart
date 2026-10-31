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

/// One page of a note (Open WebUI 0.12.5+): a note holds pages and
/// subpages, the first ("main") always there.
class NotePage {
  const NotePage({
    required this.id,
    required this.title,
    required this.markdown,
    this.parentId,
    this.revision = 0,
  });

  factory NotePage.fromJson(Map j) => NotePage(
    id: '${j['id']}',
    title: '${j['title'] ?? ''}',
    markdown: '${(j['content'] as Map?)?['md'] ?? ''}',
    parentId: j['parent_id'] as String?,
    revision: (j['revision'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String title;
  final String markdown;
  final String? parentId;
  final int revision;

  bool get isMain => id == 'main';
}

class Note {
  const Note({
    required this.id,
    required this.title,
    required this.markdown,
    required this.pinned,
    required this.updated,
    this.files = const [],
    this.pages = const [],
    this.pagesRevision = 0,
    this.pageCount,
    this.writable = true,
  });

  factory Note.fromJson(Map j) {
    final data = (j['data'] as Map?) ?? const {};
    final content = (data['content'] as Map?) ?? const {};
    return Note(
      id: '${j['id']}',
      title: '${j['title'] ?? ''}',
      markdown: '${content['md'] ?? ''}',
      pinned: j['is_pinned'] == true,
      updated: fromServerTime((j['updated_at'] as num?) ?? 0),
      files: [
        for (final f in (data['files'] as List? ?? const []).whereType<Map>())
          if (f['id'] != null) f.cast<String, dynamic>(),
      ],
      pages: [
        for (final p in (data['pages'] as List? ?? const []).whereType<Map>())
          NotePage.fromJson(p),
      ],
      pagesRevision: (data['pages_revision'] as num?)?.toInt() ?? 0,
      pageCount: (data['page_count'] as num?)?.toInt(),
      writable: j['write_access'] != false,
    );
  }

  final String id;
  final String title;

  /// The note's text as Markdown (cut short in lists). With several pages,
  /// all of them, each under its own heading.
  final String markdown;
  final bool pinned;
  final DateTime updated;

  /// Files added to the note (Upload files), as servers before 0.12.5 keep
  /// them. Since then they are links inside a page: see [pageFiles].
  final List<Map<String, dynamic>> files;

  /// The note's pages, in order (parents before their subpages); empty on
  /// servers before 0.12.5.
  final List<NotePage> pages;

  /// Sent back with each page change, so two editors can't clash.
  final int pagesRevision;

  /// In lists: how many pages the note has.
  final int? pageCount;
  final bool writable;

  /// Whether the server keeps pages (and files inside them).
  bool get paged => pages.isNotEmpty;
}

/// How deep [page] sits: 0 for a top page, 1 for its subpages...
int pageDepth(List<NotePage> pages, NotePage page) {
  var depth = 0;
  var parent = page.parentId;
  final seen = <String>{};
  while (parent != null && seen.add(parent)) {
    depth++;
    parent = pages.where((p) => p.id == parent).firstOrNull?.parentId;
  }
  return depth;
}

/// [page] and every page under it.
Set<String> pageBranch(List<NotePage> pages, String id) {
  final out = {id};
  for (final p in pages) {
    if (p.parentId != null && out.contains(p.parentId)) out.add(p.id);
  }
  return out;
}

final _fileLink = RegExp(
  r'\[([^\]]*)\]\((?:[^)\s]*?)/api/v1/files/([\w-]+)/content\)',
);

/// The files attached to a page (0.12.5+): links to the server's files in
/// its text, as the web adds them.
List<Map<String, dynamic>> pageFiles(String markdown) {
  final seen = <String>{};
  return [
    for (final m in _fileLink.allMatches(markdown))
      if (seen.add(m.group(2)!))
        {
          'type': 'file',
          'id': m.group(2),
          'name': m.group(1)!.isEmpty ? m.group(2) : m.group(1),
        },
  ];
}

/// The text with a link to [file] added at the end, as the web attaches.
String withFileLink(String markdown, Map<String, dynamic> file) {
  final name = '${file['name'] ?? file['id']}'.replaceAll(
    RegExp(r'[\[\]]'),
    '',
  );
  final link = '[$name](/api/v1/files/${file['id']}/content)';
  return markdown.trim().isEmpty ? link : '${markdown.trimRight()}\n\n$link';
}

/// The text without its links to the file [id].
String withoutFileLink(String markdown, String id) => markdown
    .replaceAll(
      RegExp(
        r'\n*\[[^\]]*\]\([^)\s]*?/api/v1/files/' +
            RegExp.escape(id) +
            r'/content\)',
      ),
      '',
    )
    .trimRight();

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
  /// [pageId] says which page the text is for (0.12.5+; older servers
  /// ignore it). [files] is only for servers before 0.12.5.
  Future<void> update(
    String id, {
    String? title,
    String? markdown,
    String? pageId,
    List<Map<String, dynamic>>? files,
  }) => client.send(
    'POST',
    '$_base/${Uri.encodeComponent(id)}/update',
    body: {
      'title': ?title,
      if (markdown != null) 'page_id': ?pageId,
      if (markdown != null || files != null)
        'data': {
          if (markdown != null) ..._content(markdown),
          // The web clears the list with null when the last one goes.
          if (files != null) 'files': files.isEmpty ? null : files,
        },
    },
  );

  /// A change to the note's pages (0.12.5+): create, rename, duplicate,
  /// move or delete one, as the web's page tabs. Returns the note as saved.
  Future<Note> pages(
    String id,
    String action, {
    required int revision,
    String? pageId,
    String? newId,
    String? parentId,
    bool toTop = false,
    String? beforeId,
    String? title,
  }) async => Note.fromJson(
    await client.send(
      'POST',
      '$_base/${Uri.encodeComponent(id)}/pages/update',
      body: {
        'action': action,
        'revision': revision,
        'page_id': ?pageId,
        'new_id': ?newId,
        if (parentId != null || toTop) 'parent_id': parentId,
        'before_id': ?beforeId,
        'title': ?title,
      },
    ) as Map,
  );

  Future<void> togglePin(String id) =>
      client.send('POST', '$_base/${Uri.encodeComponent(id)}/pin');

  Future<void> delete(String id) =>
      client.send('DELETE', '$_base/${Uri.encodeComponent(id)}/delete');
}
