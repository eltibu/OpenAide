import 'dart:convert';

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
}
