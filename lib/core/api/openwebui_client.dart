import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat.dart';
import '../models/model_info.dart';
import 'sse.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => 'Open WebUI error $statusCode: $message';
}

/// Thin client over the Open WebUI REST API.
///
/// The server is the source of truth: every chat the app creates or changes is
/// written back through these endpoints, never kept only on the device.
class OpenWebUiClient {
  OpenWebUiClient({required String baseUrl, this.token, http.Client? httpClient})
      : baseUrl = _normalize(baseUrl),
        _http = httpClient ?? http.Client();

  final String baseUrl;
  String? token;
  final http.Client _http;

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
      };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<dynamic> _send(String method, String path,
      {Object? body, Map<String, String>? query}) async {
    final req = http.Request(method, _uri(path, query))..headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await _http.send(req));
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
    return text.isEmpty ? null : jsonDecode(text);
  }

  // ---- Server & auth ----

  /// Public server config: name, version, enabled features, auth options.
  Future<Map<String, dynamic>> config() async =>
      (await _send('GET', '/api/config') as Map).cast<String, dynamic>();

  /// Email/password sign-in. Stores and returns the JWT.
  Future<String> signIn(String email, String password) async {
    final res = await _send('POST', '/api/v1/auths/signin',
        body: {'email': email, 'password': password}) as Map;
    token = res['token'] as String;
    return token!;
  }

  /// The signed-in user; also validates a stored token or API key.
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
    final res = await _send('GET', '/api/v1/chats/',
        query: {'page': '$page'}) as List;
    return [
      for (final c in res.whereType<Map>())
        ChatSummary.fromJson(c.cast<String, dynamic>()),
    ];
  }

  Future<Chat> chat(String id) async => Chat.fromServer(
      (await _send('GET', '/api/v1/chats/$id') as Map).cast<String, dynamic>());

  /// Creates the chat on the server and returns it with its server id.
  Future<Chat> createChat(Chat draft) async {
    final body = draft.toServerBody()..remove('id');
    final res = await _send('POST', '/api/v1/chats/new', body: {'chat': body});
    return Chat.fromServer((res as Map).cast<String, dynamic>());
  }

  Future<void> saveChat(Chat chat) =>
      _send('POST', '/api/v1/chats/${chat.id}', body: {'chat': chat.toServerBody()});

  Future<void> deleteChat(String id) => _send('DELETE', '/api/v1/chats/$id');

  // ---- Completions ----

  /// Streams assistant text for [messages] through Open WebUI, so the
  /// server's pipelines, filters, tools and knowledge all apply.
  Stream<String> streamCompletion({
    required String model,
    required List<Map<String, dynamic>> messages,
    Map<String, dynamic> extraParams = const {},
  }) async* {
    final req = http.Request('POST', _uri('/api/chat/completions'))
      ..headers.addAll({..._headers, 'Accept': 'text/event-stream'})
      ..body = jsonEncode({
        'model': model,
        'messages': messages,
        'stream': true,
        ...extraParams,
      });
    final res = await _http.send(req);
    if (res.statusCode >= 400) {
      throw ApiException(
          res.statusCode, await res.stream.bytesToString());
    }
    await for (final chunk in parseSse(res.stream)) {
      final error = chunk['error'];
      if (error != null) {
        throw ApiException(500, error is Map ? '${error['message']}' : '$error');
      }
      final text = deltaContent(chunk);
      if (text != null && text.isNotEmpty) yield text;
    }
  }

  /// Exchanges the first turn for a short title using the server's
  /// configured title model, matching what the web UI does.
  Future<String?> generateTitle(String model, List<Map<String, dynamic>> messages) async {
    try {
      final res = await _send('POST', '/api/v1/tasks/title/completions',
          body: {'model': model, 'messages': messages, 'stream': false}) as Map?;
      final choices = res?['choices'] as List?;
      final content =
          ((choices?.firstOrNull as Map?)?['message'] as Map?)?['content'];
      if (content is! String) return null;
      // Newer servers return JSON like {"title": "..."}.
      final match = RegExp(r'\{[\s\S]*\}').firstMatch(content);
      if (match != null) {
        final j = jsonDecode(match.group(0)!);
        if (j is Map && j['title'] is String) return j['title'] as String;
      }
      return content.trim().replaceAll('"', '');
    } catch (_) {
      return null;
    }
  }
}
