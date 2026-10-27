import 'dart:convert';
import 'dart:io';

import '../../core/api/openwebui_client.dart';

/// A terminal server the admin connected to Open WebUI (an Open Terminal:
/// a shell and a file system). The app reaches it through Open WebUI's own
/// proxy, signed in as the user, exactly as the web UI does.
class TerminalServer {
  const TerminalServer({required this.id, required this.name});

  factory TerminalServer.fromJson(Map<String, dynamic> j) => TerminalServer(
    id: '${j['id']}',
    name: '${j['name'] ?? ''}'.isEmpty ? '${j['id']}' : '${j['name']}',
  );

  final String id;
  final String name;
}

/// One file or folder in a listing.
class TerminalEntry {
  const TerminalEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.size,
    this.modified,
  });

  final String name;
  final String path;
  final bool isDir;
  final int? size;
  final DateTime? modified;
}

class TerminalListing {
  const TerminalListing({
    required this.dir,
    required this.entries,
    required this.writable,
  });
  final String dir;
  final List<TerminalEntry> entries;
  final bool writable;
}

/// Joins a folder and a name the way the server writes paths.
String joinPath(String dir, String name) =>
    dir.endsWith('/') ? '$dir$name' : '$dir/$name';

/// The folder a path is in ('/' for the top).
String parentPath(String path) {
  final i = path.lastIndexOf('/');
  return i <= 0 ? '/' : path.substring(0, i);
}

Future<List<TerminalServer>> terminalServers(OpenWebUiClient client) async {
  final res = await client.send('GET', '/api/v1/terminals/');
  return [
    for (final s in (res as List? ?? const []).whereType<Map>())
      TerminalServer.fromJson(s.cast<String, dynamic>()),
  ];
}

/// The files and shells of one terminal server.
class TerminalApi {
  TerminalApi(this.client, this.server);

  final OpenWebUiClient client;
  final TerminalServer server;

  String get _base => '/api/v1/terminals/${Uri.encodeComponent(server.id)}';

  /// The user's home and the folder the file browser starts in.
  Future<({String home, String cwd})> cwd() async {
    final j = await client.send('GET', '$_base/files/cwd') as Map;
    final root = j['root'];
    final home = '${(root is Map ? root['path'] : null) ?? j['home']}';
    return (home: home, cwd: '${j['cwd'] ?? home}');
  }

  Future<TerminalListing> list(String dir) async {
    final j = await client.send(
      'GET',
      '$_base/files/list',
      query: {'directory': dir},
    ) as Map;
    final at = '${j['dir'] ?? dir}';
    final entries =
        [
          for (final e in (j['entries'] as List? ?? const []).whereType<Map>())
            TerminalEntry(
              name: '${e['name']}',
              path: joinPath(at, '${e['name']}'),
              isDir: e['type'] == 'directory',
              size: (e['size'] as num?)?.toInt(),
              modified: e['modified'] is num
                  ? DateTime.fromMillisecondsSinceEpoch(
                      ((e['modified'] as num) * 1000).round(),
                    )
                  : null,
            ),
        ]..sort((a, b) {
          if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    return TerminalListing(
      dir: at,
      entries: entries,
      writable: j['writable'] != false,
    );
  }

  /// Files and folders under [dir] whose name holds [query], best first,
  /// as the web UI's Files search finds them (`files/search`, or a name
  /// pattern on servers without it).
  Future<List<({String path, String name, bool isDir})>> search(
    String query, {
    String dir = '.',
    int limit = 100,
  }) async {
    List<({String path, String name, bool isDir})> read(
      List? items,
      String root,
    ) => [
      for (final e in (items ?? const []).whereType<Map>())
        (
          path: '${e['path']}'.startsWith('/')
              ? '${e['path']}'
              : joinPath(root, '${e['path']}'),
          name: '${e['name'] ?? '${e['path']}'.split('/').last}',
          isDir: e['type'] == 'directory',
        ),
    ];
    try {
      final j = await client.send(
        'GET',
        '$_base/files/search',
        query: {
          'query': query,
          'path': dir,
          'limit': '$limit',
          'type': 'any',
          'show_hidden': 'false',
        },
      );
      if (j is Map && j['results'] is List) {
        return read(j['results'] as List, dir);
      }
    } catch (_) {
      // Older terminals have only the pattern search below.
    }
    final j = await client.send(
      'GET',
      '$_base/files/glob',
      query: {
        'pattern': '*$query*',
        'path': dir,
        'type': 'any',
        'max_results': '$limit',
      },
    ) as Map;
    return read(j['matches'] as List?, '${j['path'] ?? dir}');
  }

  /// A file's raw bytes.
  Future<List<int>> read(String path) =>
      client.getBytes('$_base/files/view', {'path': path});

  Future<void> write(String path, String content) => client.send(
    'POST',
    '$_base/files/write',
    body: {'path': path, 'content': content},
  );

  Future<void> upload(String dir, List<int> bytes, String name) => client
      .sendFile('$_base/files/upload', bytes, name, query: {'directory': dir});

  Future<void> mkdir(String path) =>
      client.send('POST', '$_base/files/mkdir', body: {'path': path});

  Future<void> delete(String path) =>
      client.send('DELETE', '$_base/files/delete', query: {'path': path});

  Future<void> move(String from, String to) => client.send(
    'POST',
    '$_base/files/move',
    body: {'source': from, 'destination': to},
  );

  /// Programs listening on the server's ports (port, pid, process).
  Future<List<({int port, String process})>> ports() async {
    final j = await client.send('GET', '$_base/ports');
    final list = (j is Map ? j['ports'] : j) as List? ?? const [];
    return [
      for (final p in list.whereType<Map>())
        if (p['port'] is num)
          (port: (p['port'] as num).toInt(), process: '${p['process'] ?? ''}'),
    ];
  }

  /// Where a port's web page is reached through Open WebUI, signed in.
  String proxyPath(int port) => '$_base/proxy/$port/';

  /// Starts a kernel for the notebook at [path]; returns its session id.
  Future<String> startNotebook(String path) async {
    final j = await client.send(
      'POST',
      '$_base/notebooks',
      body: {'path': path},
    );
    return '${(j as Map)['id']}';
  }

  /// Runs one cell ([source] as it is now) and returns its result:
  /// status, execution_count and outputs.
  Future<Map<String, dynamic>> runCell(
    String session,
    int index,
    String source,
  ) async {
    final j = await client.send(
      'POST',
      '$_base/notebooks/$session/execute',
      body: {'cell_index': index, 'source': source},
    );
    return (j as Map).cast<String, dynamic>();
  }

  Future<void> stopNotebook(String session) async {
    try {
      await client.send('DELETE', '$_base/notebooks/$session');
    } catch (_) {
      // Already stopped.
    }
  }

  /// Starts a shell and returns its id.
  Future<String> openShell() async {
    final j = await client.send('POST', '$_base/api/terminals') as Map;
    return '${j['id']}';
  }

  Future<void> closeShell(String id) async {
    try {
      await client.send('DELETE', '$_base/api/terminals/$id');
    } catch (_) {
      // Already gone when the connection closed.
    }
  }

  /// Connects to a shell: keystrokes go out and output comes back as binary
  /// frames, after a first message that signs in.
  Future<WebSocket> connect(String id) async {
    final http = client.uri('$_base/api/terminals/$id');
    final url = http.replace(scheme: http.scheme == 'https' ? 'wss' : 'ws');
    final ws = await WebSocket.connect(
      url.toString(),
      headers: {
        if (client.cookie != null && client.cookie!.isNotEmpty)
          'Cookie': client.cookie!,
      },
    );
    ws.add(jsonEncode({'type': 'auth', 'token': client.token, 'chat_id': ''}));
    return ws;
  }
}
