import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/api/openwebui_client.dart';
import '../notes/notes_api.dart' show fromServerTime;

class Knowledge {
  const Knowledge({
    required this.id,
    required this.name,
    required this.description,
    required this.updated,
    this.writable = true,
    this.userId,
  });

  /// Who made it.
  final String? userId;

  factory Knowledge.fromJson(Map j) => Knowledge(
    id: '${j['id']}',
    name: '${j['name'] ?? ''}',
    description: '${j['description'] ?? ''}',
    userId: j['user_id']?.toString(),
    updated: fromServerTime((j['updated_at'] as num?) ?? 0),
    writable: j['write_access'] != false,
  );

  final String id;
  final String name;
  final String description;
  final DateTime updated;
  final bool writable;
}

class KnowledgeFile {
  const KnowledgeFile({
    required this.id,
    required this.name,
    required this.updated,
    this.size,
    this.status,
  });

  factory KnowledgeFile.fromJson(Map j) {
    final meta = (j['meta'] as Map?) ?? const {};
    final data = (j['data'] as Map?) ?? const {};
    return KnowledgeFile(
      id: '${j['id']}',
      name: '${meta['name'] ?? j['filename'] ?? ''}',
      size: (meta['size'] as num?)?.toInt(),
      status: data['status'] as String?,
      updated: fromServerTime((j['updated_at'] ?? j['created_at'] ?? 0) as num),
    );
  }

  final String id;
  final String name;
  final int? size;

  /// The server reading it: pending, completed or failed.
  final String? status;
  final DateTime updated;
}

class KnowledgeFolder {
  const KnowledgeFolder(this.id, this.name);
  final String id;
  final String name;
}

class KnowledgeListing {
  const KnowledgeListing(this.folders, this.files, this.path);
  final List<KnowledgeFolder> folders;
  final List<KnowledgeFile> files;

  /// Where the listing is, top first.
  final List<KnowledgeFolder> path;
}

/// A page's address as a file name, as the web names it.
String webpageFileName(String url) {
  final name = url.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_').toLowerCase();
  return name.length > 50 ? name.substring(0, 50) : name;
}

class KnowledgeApi {
  KnowledgeApi(this.client);
  final OpenWebUiClient client;

  static const _base = '/api/v1/knowledge';
  String _id(String id) => '$_base/${Uri.encodeComponent(id)}';

  Future<List<Knowledge>> list() async {
    final out = <Knowledge>[];
    for (var page = 1; page < 20; page++) {
      final res =
          await client.send('GET', '$_base/', query: {'page': '$page'}) as Map;
      final items = (res['items'] as List? ?? const []).whereType<Map>();
      out.addAll(items.map(Knowledge.fromJson));
      if (items.isEmpty || out.length >= ((res['total'] as num?) ?? 0)) break;
    }
    return out;
  }

  Future<KnowledgeListing> files(String id, {String? folderId}) async {
    final files = <KnowledgeFile>[];
    var folders = <KnowledgeFolder>[];
    var path = <KnowledgeFolder>[];
    for (var page = 1; page < 50; page++) {
      final res = await client.send(
        'GET',
        '${_id(id)}/files',
        query: {'page': '$page', 'directory_id': folderId ?? ''},
      ) as Map;
      if (page == 1) {
        KnowledgeFolder folder(Map d) =>
            KnowledgeFolder('${d['id']}', '${d['name']}');
        folders = [
          for (final d
              in (res['directories'] as List? ?? const []).whereType<Map>())
            folder(d),
        ];
        path = [
          for (final d
              in (res['breadcrumbs'] as List? ?? const []).whereType<Map>())
            folder(d),
        ];
      }
      final items = (res['items'] as List? ?? const []).whereType<Map>();
      files.addAll(items.map(KnowledgeFile.fromJson));
      if (items.isEmpty || files.length >= ((res['total'] as num?) ?? 0)) {
        break;
      }
    }
    return KnowledgeListing(folders, files, path);
  }

  Future<Knowledge> create(String name, String description) async =>
      Knowledge.fromJson(
        await client.send(
          'POST',
          '$_base/create',
          body: {'name': name, 'description': description},
        ) as Map,
      );

  Future<void> update(String id, String name, String description) =>
      client.send(
        'POST',
        '${_id(id)}/update',
        body: {'name': name, 'description': description},
      );

  Future<void> delete(String id) => client.send('DELETE', '${_id(id)}/delete');

  /// Uploads a document and adds it, as the web does: the server reads it
  /// first, then indexes it into the collection.
  Future<void> addFile(
    String id,
    List<int> bytes,
    String filename, {
    String? folderId,
  }) async {
    final file = await client.uploadFile(bytes, filename);
    final problem = await client.waitForFile('${file['id']}');
    if (problem != null) throw Exception(problem);
    await client.send(
      'POST',
      '${_id(id)}/file/add',
      body: {'file_id': file['id'], 'directory_id': ?folderId},
    );
  }

  /// Reads a web page (or a video's transcript) on the server and adds what
  /// it says, as the web's "Add webpage".
  Future<void> addWebpage(String id, String url, {String? folderId}) async {
    final res = await client.send(
      'POST',
      '/api/v1/retrieval/process/url',
      body: {'url': url, 'collection_name': null},
    ) as Map;
    final type = res['type'];
    if (type == 'web' || type == 'youtube' || res['file'] == null) {
      await addText(
        id,
        webpageFileName(url),
        '${res['content'] ?? ''}',
        folderId: folderId,
      );
      return;
    }
    await client.send(
      'POST',
      '${_id(id)}/file/add',
      body: {'file_id': (res['file'] as Map)['id'], 'directory_id': ?folderId},
    );
  }

  /// Adds typed text as a .txt document.
  Future<void> addText(
    String id,
    String name,
    String content, {
    String? folderId,
  }) => addFile(id, utf8.encode(content), '$name.txt', folderId: folderId);

  Future<void> removeFile(String id, String fileId) =>
      client.send('POST', '${_id(id)}/file/remove', body: {'file_id': fileId});

  /// What a folder on the phone changes here: added, modified (with the
  /// copy they replace), deleted, folders to make and to remove.
  Future<Map<String, dynamic>> syncDiff(
    String id,
    List<FolderFile> manifest,
  ) async => (await client.send(
    'POST',
    '${_id(id)}/sync/diff',
    body: {
      'manifest': [
        for (final f in manifest)
          {
            'filename': f.filename,
            'path': f.path,
            'checksum': f.checksum,
            'size': f.size,
          },
      ],
    },
  ) as Map).cast<String, dynamic>();

  Future<void> syncCleanup(
    String id,
    List<String> fileIds,
    List<String> dirIds,
  ) => client.send(
    'POST',
    '${_id(id)}/sync/cleanup',
    body: {'file_ids': fileIds, 'dir_ids': dirIds},
  );

  /// Makes a folder (in [parentId], else at the top); its id.
  Future<String> createFolder(
    String id,
    String name, {
    String? parentId,
  }) async =>
      '${((await client.send('POST', '${_id(id)}/dirs/create', body: {'name': name, 'parent_id': ?parentId})) as Map)['id']}';

  /// Uploads a file straight into the knowledge base and [folderId], with
  /// its checksum so the next sync knows it.
  Future<void> uploadInto(String id, FolderFile f, {String? folderId}) async {
    final file = await client.uploadFile(
      await f.file.readAsBytes(),
      f.filename,
      metadata: {
        'knowledge_id': id,
        'file_hash': f.checksum,
        'directory_id': folderId,
      },
    );
    final problem = await client.waitForFile('${file['id']}');
    if (problem != null) throw Exception(problem);
  }

  /// A folder from the phone into this knowledge base, as the web's Upload
  /// directory ([sync] false: new and changed files go in, under [under]
  /// and [underId], the folder you're in) or Sync directory ([sync] true:
  /// the knowledge base is made to match the folder, removing what isn't
  /// in it). Returns what happened.
  Future<FolderSync> addFolder(
    String id,
    Directory root, {
    required bool sync,
    String under = '',
    String? underId,
    void Function(String status)? progress,
  }) async {
    final files = await readFolder(root);
    if (files.isEmpty) return const FolderSync(0, 0, 0, 0, 0);
    String place(String path) => sync || under.isEmpty
        ? path
        : path.isEmpty
        ? under
        : '$under/$path';
    final manifest = [
      for (final f in files)
        FolderFile(f.file, place(f.path), f.filename, f.checksum, f.size),
    ];
    progress?.call('Comparing with the knowledge base…');
    final diff = await syncDiff(id, manifest);
    List<Map> list(String k) =>
        (diff[k] as List? ?? const []).whereType<Map>().toList();
    final added = list('added');
    final modified = list('modified');
    final deleted = list('deleted');
    if (sync) {
      final stale = [
        for (final d in deleted) '${d['file_id']}',
        for (final m in modified) '${m['stale_file_id']}',
      ];
      final rmdir = [for (final d in diff['rmdir'] as List? ?? const []) '$d'];
      if (stale.isNotEmpty || rmdir.isNotEmpty) {
        progress?.call('Removing ${stale.length} old files…');
        await syncCleanup(id, stale, rmdir);
      }
    }
    final ids = <String, String>{
      for (final e in ((diff['directory_map'] as Map?) ?? const {}).entries)
        '${e.key}': '${e.value}',
    };
    for (final path in (diff['mkdir'] as List? ?? const []).map((p) => '$p')) {
      final cut = path.lastIndexOf('/');
      final parent = cut < 0 ? null : ids[path.substring(0, cut)];
      ids[path] = await createFolder(
        id,
        cut < 0 ? path : path.substring(cut + 1),
        parentId: parent,
      );
    }
    bool listed(List<Map> l, FolderFile f) =>
        l.any((a) => a['filename'] == f.filename && a['path'] == f.path);
    final todo = [
      for (final f in manifest)
        if (listed(added, f) || listed(modified, f)) f,
    ];
    var failed = 0;
    for (final (i, f) in todo.indexed) {
      progress?.call('Uploading ${i + 1}/${todo.length}: ${f.filename}');
      try {
        await uploadInto(
          id,
          f,
          folderId: f.path.isEmpty ? (sync ? null : underId) : ids[f.path],
        );
      } catch (_) {
        failed++;
      }
    }
    return FolderSync(
      added.length,
      modified.length,
      sync ? deleted.length : 0,
      (diff['unmodified_count'] as num?)?.toInt() ?? 0,
      failed,
    );
  }
}

/// A file from a folder on the phone: where it sits (folder names joined
/// with /, starting with the picked folder's own name), its SHA-256 and
/// size, as the web's sync compares them.
class FolderFile {
  const FolderFile(
    this.file,
    this.path,
    this.filename,
    this.checksum,
    this.size,
  );
  final File file;
  final String path;
  final String filename;
  final String checksum;
  final int size;
}

class FolderSync {
  const FolderSync(
    this.added,
    this.modified,
    this.deleted,
    this.unchanged,
    this.failed,
  );
  final int added;
  final int modified;
  final int deleted;
  final int unchanged;
  final int failed;

  String get summary =>
      '$added added, $modified changed, $deleted removed, $unchanged unchanged'
      '${failed > 0 ? '; $failed failed to upload' : ''}.';
}

/// Every file in [root] and its folders, skipping hidden ones, as the web
/// reads a picked folder.
Future<List<FolderFile>> readFolder(Directory root) async {
  final name = root.uri.pathSegments.where((p) => p.isNotEmpty).last;
  final base = root.path.endsWith('/') ? root.path : '${root.path}/';
  final out = <FolderFile>[];
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (e is! File || !e.path.startsWith(base)) continue;
    final parts = e.path.substring(base.length).split('/');
    if (parts.any((p) => p.startsWith('.'))) continue;
    final bytes = await e.readAsBytes();
    out.add(
      FolderFile(
        e,
        [name, ...parts.take(parts.length - 1)].join('/'),
        parts.last,
        sha256.convert(bytes).toString(),
        bytes.length,
      ),
    );
  }
  return out;
}
