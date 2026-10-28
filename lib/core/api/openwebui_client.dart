import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/chat.dart';
import '../models/model_info.dart';
import 'sse.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message, {this.redirectTo});
  final int statusCode;
  final String message;

  /// Set when the server answered with a redirect (e.g. http → https).
  final Uri? redirectTo;

  @override
  String toString() =>
      statusCode >= 400 ? 'Open WebUI error $statusCode: $message' : message;
}

/// Thin client over the Open WebUI REST API.
///
/// The server is the source of truth: every chat the app creates or changes is
/// written back through these endpoints, never kept only on the device.
class OpenWebUiClient {
  OpenWebUiClient({
    required String baseUrl,
    this.token,
    this.cookie,
    http.Client? httpClient,
  }) : baseUrl = _normalize(baseUrl),
       _http = httpClient ?? http.Client();

  final String baseUrl;
  String? token;

  /// Cookies from an in-app browser sign-in, sent with every request so they
  /// pass a login gate (reverse-proxy portal) in front of Open WebUI.
  final String? cookie;
  final http.Client _http;

  /// Normalizes a typed address the same way the client does.
  static String normalizeUrl(String url) => _normalize(url);

  static String _normalize(String url) {
    var u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
    if (cookie != null && cookie!.isNotEmpty) 'Cookie': cookie!,
  };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final url = _uri(path, query);
    final res = await http.Response.fromStream(
      await _open(() {
        final req = http.Request(method, url)..headers.addAll(_headers);
        if (body != null) req.body = jsonEncode(body);
        return req;
      }),
    );
    final text = utf8.decode(res.bodyBytes);
    if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400)) {
      final location = res.headers['location'];
      throw ApiException(
        res.statusCode,
        'The server redirected to ${location ?? 'another address'}. '
        'Use that address instead.',
        redirectTo: location == null ? null : url.resolve(location),
      );
    }
    if (res.statusCode >= 400) {
      var message = text;
      try {
        final j = jsonDecode(text);
        if (j is Map && (j['detail'] ?? j['error']) != null) {
          message = '${j['detail'] ?? j['error']}';
        }
      } on FormatException {
        // Non-JSON error body; use as-is.
      }
      throw ApiException(res.statusCode, message);
    }
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      throw ApiException(res.statusCode, _notOpenWebUi);
    }
  }

  /// Sends a request built by [build]. Redirects are surfaced instead of
  /// followed (POSTs can't follow them, and [discover] uses them to find the
  /// right address). Failures to connect at all, such as a phone's DNS
  /// lookup briefly failing, are retried; the request never left the phone,
  /// so retrying can't duplicate anything.
  Future<http.StreamedResponse> _open(http.BaseRequest Function() build) async {
    const delays = [Duration(milliseconds: 600), Duration(seconds: 2)];
    for (var attempt = 0; ; attempt++) {
      final req = build()..followRedirects = false;
      try {
        return await _http.send(req);
      } catch (e) {
        if (!isConnectError(e)) rethrow;
        if (attempt >= delays.length) {
          throw ApiException(
            0,
            "Can't reach ${req.url.host}. Check your internet connection, "
            'then tap Retry.',
          );
        }
        await Future<void>.delayed(delays[attempt]);
      }
    }
  }

  /// True for errors where no connection was made (DNS, refused, offline).
  static bool isConnectError(Object e) {
    final text = '$e';
    return text.contains('Failed host lookup') ||
        text.contains('Connection refused') ||
        text.contains('Network is unreachable') ||
        text.contains('No route to host') ||
        text.contains('Connection failed');
  }

  static const _notOpenWebUi =
      'The server answered with a web page instead of Open WebUI data. '
      'Check the address (just the part before any /path), and whether a '
      'login page or proxy sits in front of Open WebUI.';

  /// Finds the Open WebUI base URL for what the user typed: tries it as
  /// given, then without any path (people often paste a chat or /auth link),
  /// and https before http when no scheme was typed.
  static Future<String> discover(
    String input, {
    http.Client? httpClient,
  }) async {
    final typed = input.trim();
    final hasScheme =
        typed.startsWith('http://') || typed.startsWith('https://');
    final schemes = hasScheme ? [''] : ['https://', 'http://'];
    final candidates = <String>[];
    for (final scheme in schemes) {
      // A pasted chat link can carry ?query or #fragment: drop them, then
      // try the address as given and the bare site.
      final uri = Uri.parse(_normalize('$scheme$typed'));
      candidates
        ..add(_normalize('${uri.origin}${uri.path}'))
        ..add(uri.origin);
    }
    Object? lastError;
    final tried = <String>{};
    while (candidates.isNotEmpty && tried.length < 8) {
      final base = candidates.removeAt(0);
      if (!tried.add(base)) continue;
      try {
        final config = await OpenWebUiClient(
          baseUrl: base,
          httpClient: httpClient,
        ).config();
        if (config.containsKey('version') || config.containsKey('name')) {
          return base;
        }
      } on ApiException catch (e) {
        lastError = e;
        final to = e.redirectTo;
        if (to != null) {
          // Follow the redirect's base, e.g. http://x → https://x.
          final p = to.path;
          final basePath = p.endsWith('/api/config')
              ? p.substring(0, p.length - '/api/config'.length)
              : '';
          candidates.insert(
            0,
            _normalize(
              to
                  .replace(path: basePath, query: null)
                  .toString()
                  .replaceAll(RegExp(r'[?#]$'), ''),
            ),
          );
        }
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError is ApiException) throw lastError;
    throw ApiException(
      0,
      'Could not reach an Open WebUI server at "$typed". ${lastError ?? ''}'
          .trim(),
    );
  }

  // ---- Server & auth ----

  /// Public server config: name, version, enabled features, auth options.
  Future<Map<String, dynamic>> config() async =>
      (await _send('GET', '/api/config') as Map).cast<String, dynamic>();

  /// Email/password sign-in. Stores and returns the JWT.
  Future<String> signIn(String email, String password) async {
    final res = await _send(
      'POST',
      '/api/v1/auths/signin',
      body: {'email': email, 'password': password},
    ) as Map;
    token = res['token'] as String;
    return token!;
  }

  /// The signed-in user; also validates a stored token or API key.
  /// The person's settings, merged with the server's interface defaults.
  Future<Map<String, dynamic>> userSettings() async =>
      ((await _send('GET', '/api/v1/users/user/settings') as Map?) ?? {})
          .cast<String, dynamic>();

  Future<Map<String, dynamic>> me() async =>
      (await _send('GET', '/api/v1/auths/') as Map).cast<String, dynamic>();

  // ---- Models ----

  Future<List<ModelInfo>> models() async {
    final res = await _send('GET', '/api/models');
    final list = res is Map ? res['data'] as List? ?? [] : res as List;
    return [
      for (final m in list.whereType<Map>())
        ModelInfo.fromJson(m.cast<String, dynamic>()),
    ];
  }

  // ---- Chats (stored on the server) ----

  Future<List<ChatSummary>> chats({int page = 1}) async {
    final res =
        await _send('GET', '/api/v1/chats/', query: {'page': '$page'}) as List;
    return [
      for (final c in res.whereType<Map>())
        ChatSummary.fromJson(c.cast<String, dynamic>()),
    ];
  }

  Future<Chat> chat(String id) async => Chat.fromServer(
    (await _send('GET', '/api/v1/chats/$id') as Map).cast<String, dynamic>(),
  );

  /// Creates the chat on the server and returns it with its server id.
  Future<Chat> createChat(Chat draft) async {
    final body = draft.toServerBody()..remove('id');
    final res = await _send('POST', '/api/v1/chats/new', body: {'chat': body});
    return Chat.fromServer((res as Map).cast<String, dynamic>());
  }

  Future<void> saveChat(Chat chat) => _send(
    'POST',
    '/api/v1/chats/${chat.id}',
    body: {'chat': chat.toServerBody()},
  );

  /// A chat's answers to its model's Chat Variables.
  Future<void> saveChatVariables(String id, Map<String, dynamic> values) =>
      _send(
        'POST',
        '/api/v1/chats/$id',
        body: {'chat': <String, dynamic>{}, 'variables': values},
      );

  Future<void> deleteChat(String id) => _send('DELETE', '/api/v1/chats/$id');

  /// Saves a chat's own system prompt and model settings (its Controls).
  Future<void> saveChatParams(String id, Map<String, dynamic> params) =>
      _send('PATCH', '/api/v1/chats/$id/params', body: params);

  /// Changes only the given top-level parts of a chat; `history` is merged
  /// on the server, so messages saved meanwhile stay.
  Future<void> patchChat(String id, Map<String, dynamic> chat) =>
      _send('POST', '/api/v1/chats/$id', body: {'chat': chat});

  /// Changes one message's text (editing a reply in place, as on the web).
  Future<void> saveMessageText(String chatId, String messageId, String text) =>
      _send(
        'POST',
        '/api/v1/chats/$chatId/messages/$messageId',
        body: {'content': text},
      );

  /// Deletes a message and its direct answers; their answers move up a
  /// level. Returns the chat as the server now has it.
  Future<Chat> deleteMessage(String chatId, String messageId) async {
    final res = await _send(
      'DELETE',
      '/api/v1/chats/$chatId/messages/$messageId',
    );
    return Chat.fromServer((res as Map).cast<String, dynamic>());
  }

  /// Answers a reply that is waiting on the person: [action] is `approve` or
  /// `reject` for a tool call, `answer` (with [answers]) for the model's
  /// questions. The server carries on with the reply itself; returns the
  /// ids of the tasks now writing it.
  Future<List<String>> resolveToolCall(
    String chatId,
    String messageId,
    String callId,
    String action, {
    Map<String, dynamic>? answers,
  }) async {
    final res = await _send(
      'POST',
      '/api/v1/chats/$chatId/messages/$messageId/resolve',
      body: {
        'call_id': callId,
        'action': action,
        'answers': ?answers,
        if (action == 'answer') 'timed_out': false,
      },
    );
    if (res is! Map) return const [];
    return [
      ...(res['task_ids'] as List? ?? const []).whereType<String>(),
      if (res['task_id'] is String) res['task_id'] as String,
    ];
  }

  /// Records a thumbs up/down (and its reason) for Admin > Evaluations, the
  /// same record the web UI keeps. Returns the feedback id.
  Future<String?> saveFeedback(
    Map<String, dynamic> feedback, {
    String? id,
  }) async {
    if (id != null) {
      try {
        final res = await _send(
          'POST',
          '/api/v1/evaluations/feedback/$id',
          body: feedback,
        );
        if (res is Map && res['id'] is String) return res['id'] as String;
      } on ApiException {
        // Gone or not ours any more: make a new one.
      }
    }
    final res = await _send(
      'POST',
      '/api/v1/evaluations/feedback',
      body: feedback,
    );
    return res is Map ? res['id'] as String? : null;
  }

  /// Saves a message's voice-call details (`meta.voice`).
  Future<void> saveMessageVoice(
    String chatId,
    String messageId,
    Map<String, dynamic> voice,
  ) => _send(
    'POST',
    '/api/v1/chats/$chatId/messages/$messageId',
    body: {'voice': voice},
  );

  /// Pinned chats; the main list leaves them out, as on the web.
  Future<List<ChatSummary>> pinnedChats() async =>
      _summaries(await _send('GET', '/api/v1/chats/pinned'));

  /// Chats whose title or messages match [text] (`tag:x` works too).
  Future<List<ChatSummary>> searchChats(String text, {int page = 1}) async =>
      _summaries(
        await _send(
          'GET',
          '/api/v1/chats/search',
          query: {'text': text, 'page': '$page'},
        ),
      );

  /// Chats in a folder, ten per page like the web UI's sidebar.
  Future<List<ChatSummary>> folderChats(
    String folderId, {
    int page = 1,
  }) async => _summaries(
    await _send(
      'GET',
      '/api/v1/chats/folder/$folderId/list',
      query: {'page': '$page'},
    ),
  );

  List<ChatSummary> _summaries(Object? res) => [
    for (final c in (res as List? ?? const []).whereType<Map>())
      ChatSummary.fromJson(c.cast<String, dynamic>()),
  ];

  /// Changes only the title; the server keeps the rest of the chat.
  Future<void> renameChat(String id, String title) => _send(
    'POST',
    '/api/v1/chats/$id',
    body: {
      'chat': {'title': title},
    },
  );

  /// Pins or unpins (the server toggles it).
  Future<void> togglePin(String id) => _send('POST', '/api/v1/chats/$id/pin');

  /// Archives or unarchives (the server toggles it).
  Future<void> toggleArchive(String id) =>
      _send('POST', '/api/v1/chats/$id/archive');

  /// Moves a chat into [folderId], or out of any folder with null.
  Future<void> moveChat(String id, String? folderId) =>
      _send('POST', '/api/v1/chats/$id/folder', body: {'folder_id': folderId});

  // ---- Folders ----

  Future<List<Folder>> folders() async {
    final res = await _send('GET', '/api/v1/folders/') as List? ?? const [];
    return [
      for (final f in res.whereType<Map>())
        Folder.fromJson(f.cast<String, dynamic>()),
    ];
  }

  Future<void> createFolder(String name, {String? parentId}) => _send(
    'POST',
    '/api/v1/folders/',
    body: {'name': name, 'parent_id': ?parentId},
  );

  Future<void> renameFolder(String id, String name) =>
      _send('POST', '/api/v1/folders/$id/update', body: {'name': name});

  /// Deletes the folder; its chats move back to the main list.
  Future<void> deleteFolder(String id) => _send(
    'DELETE',
    '/api/v1/folders/$id',
    query: {'delete_contents': 'false'},
  );

  // ---- Completions ----

  /// Streams assistant text for [messages] through Open WebUI, so the
  /// server's pipelines, filters, tools and knowledge all apply.
  Stream<String> streamCompletion({
    required String model,
    required List<Map<String, dynamic>> messages,
    Map<String, dynamic> extraParams = const {},
  }) => _streamText('/api/chat/completions', {
    'model': model,
    'messages': messages,
    'stream': true,
    ...extraParams,
  });

  /// Streams one answer that merges several models' [responses] to [prompt]
  /// (Merge Responses on the web), written by [model].
  Stream<String> streamMerge({
    required String model,
    required String prompt,
    required List<String> responses,
  }) => _streamText('/api/v1/tasks/moa/completions', {
    'model': model,
    'prompt': prompt,
    'responses': responses,
    'stream': true,
  });

  /// A request whose answer comes as JSON lines (Ollama's pull progress),
  /// or as `data:` lines; each object as it arrives.
  Stream<Map<String, dynamic>> streamJson(
    String method,
    String path,
    Map<String, dynamic> body,
  ) async* {
    final res = await _open(
      () => http.Request(method, _uri(path))
        ..headers.addAll(_headers)
        ..body = jsonEncode(body),
    );
    if (res.statusCode >= 400) {
      throw ApiException(
        res.statusCode,
        _errorText(await res.stream.toBytes()),
      );
    }
    final lines = res.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (var line in lines) {
      line = line.trim();
      if (line.startsWith('data:')) line = line.substring(5).trim();
      if (line.isEmpty || line == '[DONE]') continue;
      try {
        final j = jsonDecode(line);
        if (j is Map) yield j.cast<String, dynamic>();
      } on FormatException {
        // Not JSON: skip it.
      }
    }
  }

  Stream<String> _streamText(String path, Map<String, dynamic> body) async* {
    final res = await _open(
      () => http.Request('POST', _uri(path))
        ..headers.addAll({..._headers, 'Accept': 'text/event-stream'})
        ..body = jsonEncode(body),
    );
    if (res.statusCode >= 300 && res.statusCode < 400) {
      throw ApiException(
        res.statusCode,
        'Your sign-in expired. Sign out and sign in again.',
        redirectTo: Uri.tryParse(res.headers['location'] ?? ''),
      );
    }
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, await res.stream.bytesToString());
    }
    await for (final chunk in parseSse(res.stream)) {
      final error = chunk['error'];
      if (error != null) {
        throw ApiException(
          500,
          error is Map ? '${error['message']}' : '$error',
        );
      }
      final text = deltaContent(chunk);
      if (text != null && text.isNotEmpty) yield text;
    }
  }

  /// Starts a reply the way the web UI does: Open WebUI stores the user
  /// message and an empty reply [replyId] in the chat, then runs the model as
  /// a background task with the chat's tools, memory and filters, saves the
  /// answer on the server, and pushes progress to socket [sessionId].
  ///
  /// [chatId] null starts a new chat. [options] carries what the web UI adds
  /// (tool_ids, filter_ids, terminal_id, features, params). Returns the chat
  /// id and the task ids.
  Future<({String chatId, List<String> taskIds})> startTurn({
    required String model,
    required String? chatId,
    required ChatMessage userMessage,
    required String replyId,
    required List<Map<String, dynamic>> messages,
    required String sessionId,
    Map<String, dynamic> options = const {},
  }) async {
    final res = await _send(
      'POST',
      '/api/chat/completions',
      body: {
        'model': model,
        'messages': messages,
        'stream': true,
        'chat_id': ?chatId,
        'parent_id': userMessage.parentId,
        'id': replyId,
        'user_message': {
          ...userMessage.toJson(),
          'models': [model],
        },
        'session_id': sessionId,
        'background_tasks': {'title_generation': true, 'tags_generation': true},
        ...options,
      },
    );
    if (res is! Map || res['chat_id'] is! String) {
      throw ApiException(
        500,
        'This Open WebUI is too old for the app (it did not start the reply '
        'as a server task). Update Open WebUI and try again.',
      );
    }
    return (
      chatId: res['chat_id'] as String,
      taskIds: (res['task_ids'] as List? ?? []).whereType<String>().toList(),
    );
  }

  /// Uploads a file the way the web UI's attach button does and returns the
  /// server's file record. [process] extracts the text for the model to read;
  /// photos skip it, since the model looks at them directly.
  Future<Map<String, dynamic>> uploadFile(
    List<int> bytes,
    String filename, {
    String? contentType,
    bool process = true,
  }) async {
    final url = _uri('/api/v1/files/', {'process': '$process'});
    final res = await http.Response.fromStream(
      await _open(() {
        final req = http.MultipartRequest('POST', url)
          ..headers.addAll(authHeaders)
          ..headers['Accept'] = 'application/json'
          ..files.add(
            http.MultipartFile.fromBytes(
              'file',
              bytes,
              filename: filename,
              contentType: contentType == null
                  ? null
                  : MediaType.parse(contentType),
            ),
          );
        return req;
      }),
    );
    final text = utf8.decode(res.bodyBytes);
    if (res.statusCode >= 400) {
      var message = text;
      try {
        final j = jsonDecode(text);
        if (j is Map && j['detail'] != null) message = '${j['detail']}';
      } on FormatException {
        // Non-JSON error body; use as-is.
      }
      throw ApiException(res.statusCode, message);
    }
    final j = jsonDecode(text);
    if (j is! Map || j['id'] is! String) {
      throw ApiException(res.statusCode, _notOpenWebUi);
    }
    return j.cast<String, dynamic>();
  }

  /// Waits while the server reads an uploaded document, as the web UI does
  /// before letting it be sent. Returns the server's problem with the file,
  /// or null once it's ready.
  Future<String?> waitForFile(
    String id, {
    Duration every = const Duration(seconds: 1),
    Duration limit = const Duration(minutes: 5),
  }) async {
    final end = DateTime.now().add(limit);
    while (DateTime.now().isBefore(end)) {
      final res = await _send('GET', '/api/v1/files/$id/process/status');
      final status = res is Map ? res['status'] : null;
      if (status == 'completed' || status == null) return null;
      if (status == 'failed') {
        final file = await _send('GET', '/api/v1/files/$id');
        final data = file is Map ? file['data'] : null;
        return '${(data is Map ? data['error'] : null) ?? 'The server could not read this file.'}';
      }
      await Future<void>.delayed(every);
    }
    return 'The server is still reading this file.';
  }

  /// Where an uploaded file's bytes are served (needs [authHeaders]).
  Uri fileContentUri(String id) => _uri('/api/v1/files/$id/content');

  /// A path on the server (such as `/api/v1/files/<id>/content` or
  /// `/static/...`) as a full address; full addresses are kept.
  Uri serverUri(String pathOrUrl) => pathOrUrl.startsWith('http')
      ? Uri.parse(pathOrUrl)
      : Uri.parse('$baseUrl$pathOrUrl');

  /// Sign-in headers alone, for images and uploads.
  Map<String, String> get authHeaders => {
    if (token != null) 'Authorization': 'Bearer $token',
    if (cookie != null && cookie!.isNotEmpty) 'Cookie': cookie!,
  };

  /// Any JSON endpoint of the server, for features that wrap its APIs
  /// directly (terminal servers, notes...).
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) => _send(method, path, body: body, query: query);

  /// A full address on the server.
  Uri uri(String path, [Map<String, String>? query]) => _uri(path, query);

  /// The raw bytes an endpoint serves (file contents).
  Future<List<int>> getBytes(String path, [Map<String, String>? query]) async {
    final res = await http.Response.fromStream(
      await _open(
        () =>
            http.Request('GET', _uri(path, query))..headers.addAll(authHeaders),
      ),
    );
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, _errorText(res.bodyBytes));
    }
    return res.bodyBytes;
  }

  /// Posts JSON and returns the raw bytes served back (spoken audio).
  Future<List<int>> postForBytes(String path, Object body) async {
    final res = await http.Response.fromStream(
      await _open(
        () => http.Request('POST', _uri(path))
          ..headers.addAll(authHeaders)
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode(body),
      ),
    );
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, _errorText(res.bodyBytes));
    }
    return res.bodyBytes;
  }

  /// Posts one file as multipart form data to [path].
  Future<dynamic> sendFile(
    String path,
    List<int> bytes,
    String filename, {
    Map<String, String>? query,
    MediaType? contentType,
    Map<String, String>? fields,
  }) async {
    final res = await http.Response.fromStream(
      await _open(
        () => http.MultipartRequest('POST', _uri(path, query))
          ..headers.addAll(authHeaders)
          ..headers['Accept'] = 'application/json'
          ..fields.addAll(fields ?? const {})
          ..files.add(
            http.MultipartFile.fromBytes(
              'file',
              bytes,
              filename: filename,
              contentType: contentType,
            ),
          ),
      ),
    );
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, _errorText(res.bodyBytes));
    }
    final text = utf8.decode(res.bodyBytes);
    return text.isEmpty ? null : jsonDecode(text);
  }

  /// Posts several files under one form [field], with plain [fields].
  Future<dynamic> sendFiles(
    String path,
    List<(List<int>, String)> files, {
    String field = 'files',
    Map<String, String>? fields,
  }) async {
    final res = await http.Response.fromStream(
      await _open(
        () => http.MultipartRequest('POST', _uri(path))
          ..headers.addAll(authHeaders)
          ..headers['Accept'] = 'application/json'
          ..fields.addAll(fields ?? const {})
          ..files.addAll([
            for (final (bytes, name) in files)
              http.MultipartFile.fromBytes(field, bytes, filename: name),
          ]),
      ),
    );
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, _errorText(res.bodyBytes));
    }
    final text = utf8.decode(res.bodyBytes);
    return text.isEmpty ? null : jsonDecode(text);
  }

  static String _errorText(List<int> body) {
    final text = utf8.decode(body, allowMalformed: true);
    try {
      final j = jsonDecode(text);
      if (j is Map && (j['detail'] ?? j['error']) != null) {
        return '${j['detail'] ?? j['error']}';
      }
    } on FormatException {
      // Not JSON; use as-is.
    }
    return text;
  }

  /// Stops a running reply; what was written so far stays saved.
  Future<void> stopTask(String taskId) =>
      _send('POST', '/api/tasks/stop/$taskId');
}
