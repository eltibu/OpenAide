/// A client for remote MCP servers (Model Context Protocol): the newer
/// Streamable HTTP transport, and the older HTTP + SSE one for servers
/// that only have that. Lists a server's tools and calls them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api/sse.dart';
import '../net/local_network.dart';

const mcpProtocolVersion = '2025-06-18';

class McpException implements Exception {
  McpException(this.message, {this.statusCode, this.authenticate});
  final String message;
  final int? statusCode;

  /// The server's WWW-Authenticate header when it wants a sign-in.
  final String? authenticate;

  bool get needsSignIn => statusCode == 401;

  @override
  String toString() => message;
}

/// A tool an MCP server offers.
class McpTool {
  const McpTool(this.name, this.description, this.inputSchema, {this.title});
  final String name;
  final String? title;
  final String description;
  final Map<String, dynamic> inputSchema;

  factory McpTool.fromJson(Map json) => McpTool(
    '${json['name']}',
    '${json['description'] ?? ''}',
    json['inputSchema'] is Map
        ? (json['inputSchema'] as Map).cast<String, dynamic>()
        : const {'type': 'object', 'properties': {}},
    title:
        (json['annotations'] as Map?)?['title'] as String? ??
        json['title'] as String?,
  );
}

/// One connection to an MCP server. [token] is sent as a bearer token;
/// [headers] go with every request.
class McpClient {
  McpClient(
    this.url, {
    this.token,
    this.headers = const {},
    http.Client? httpClient,
  }) : _client = EncryptedOnlyClient(httpClient),
       _ownsClient = httpClient == null;

  final String url;
  String? token;
  final Map<String, String> headers;
  final http.Client _client;
  final bool _ownsClient;

  String? _session;
  bool _ready = false;
  int _id = 0;
  Map<String, dynamic>? serverInfo;
  String? instructions;

  // The older transport: an SSE stream that answers, and an address to
  // post to.
  bool _legacy = false;
  Uri? _postUrl;
  StreamSubscription<SseEvent>? _legacySub;
  final _waiting = <int, Completer<Map<String, dynamic>>>{};

  Map<String, String> get _auth => {
    ...headers,
    if (token != null && token!.isNotEmpty) 'Authorization': 'Bearer $token',
  };

  Future<void> _ensureReady() async {
    if (_ready) return;
    final init = {
      'protocolVersion': mcpProtocolVersion,
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'OpenAide', 'version': '1.0'},
    };
    Map<String, dynamic> result;
    try {
      result = await _request('initialize', init, initializing: true);
    } on McpException catch (e) {
      // Servers from before Streamable HTTP don't take a POST here.
      if (e.statusCode == 404 || e.statusCode == 405 || e.statusCode == 400) {
        await _openLegacy();
        result = await _request('initialize', init, initializing: true);
      } else {
        rethrow;
      }
    }
    serverInfo = (result['serverInfo'] as Map?)?.cast<String, dynamic>();
    instructions = result['instructions'] as String?;
    _ready = true;
    await _notify('notifications/initialized');
  }

  /// Every tool the server has.
  Future<List<McpTool>> listTools() async {
    await _ensureReady();
    final tools = <McpTool>[];
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final r = await _request('tools/list', {'cursor': ?cursor});
      for (final t in (r['tools'] as List? ?? const []).whereType<Map>()) {
        tools.add(McpTool.fromJson(t));
      }
      cursor = r['nextCursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
    return tools;
  }

  /// Calls [name] and returns what it said, as text for the model.
  Future<({String text, bool isError})> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    await _ensureReady();
    final r = await _request('tools/call', {
      'name': name,
      'arguments': args,
    }, timeout: const Duration(seconds: 120));
    return (text: mcpResultText(r), isError: r['isError'] == true);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params, {
    bool initializing = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final id = ++_id;
    final body = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    };
    if (_legacy) return _legacyRequest(id, body, timeout);
    final res = await _client
        .send(
          http.Request('POST', Uri.parse(url))
            ..headers.addAll({
              ..._auth,
              'Content-Type': 'application/json',
              'Accept': 'application/json, text/event-stream',
              if (!initializing) 'MCP-Protocol-Version': mcpProtocolVersion,
              'Mcp-Session-Id': ?_session,
            })
            ..body = jsonEncode(body),
        )
        .timeout(timeout);
    final session = res.headers['mcp-session-id'];
    if (session != null && session.isNotEmpty) _session = session;
    if (res.statusCode == 404 && _session != null && !initializing) {
      // The server forgot the session: start again once.
      _session = null;
      _ready = false;
      await res.stream.drain<void>();
      await _ensureReady();
      return _request(method, params, timeout: timeout);
    }
    if (res.statusCode >= 400) {
      final text = await res.stream.bytesToString();
      throw McpException(
        _errorText(res.statusCode, text),
        statusCode: res.statusCode,
        authenticate: res.headers['www-authenticate'],
      );
    }
    final type = res.headers['content-type'] ?? '';
    Map<String, dynamic>? answer;
    if (type.contains('text/event-stream')) {
      await for (final event in parseSse(res.stream).timeout(timeout)) {
        if (event['id'] == id &&
            (event.containsKey('result') || event.containsKey('error'))) {
          answer = event;
          break;
        }
      }
    } else {
      final text = await res.stream.bytesToString();
      final json = jsonDecode(text);
      if (json is List) {
        answer = json
            .whereType<Map<String, dynamic>>()
            .where((m) => m['id'] == id)
            .firstOrNull;
      } else if (json is Map<String, dynamic>) {
        answer = json;
      }
    }
    return _result(answer);
  }

  Map<String, dynamic> _result(Map<String, dynamic>? answer) {
    if (answer == null) throw McpException('The MCP server sent no answer.');
    final error = answer['error'];
    if (error is Map) {
      throw McpException('${error['message'] ?? 'MCP error ${error['code']}'}');
    }
    final result = answer['result'];
    return result is Map ? result.cast<String, dynamic>() : {};
  }

  Future<void> _notify(String method) async {
    final body = jsonEncode({'jsonrpc': '2.0', 'method': method});
    try {
      if (_legacy) {
        await _client.post(
          _postUrl!,
          headers: {..._auth, 'Content-Type': 'application/json'},
          body: body,
        );
        return;
      }
      final res = await _client.post(
        Uri.parse(url),
        headers: {
          ..._auth,
          'Content-Type': 'application/json',
          'Accept': 'application/json, text/event-stream',
          'MCP-Protocol-Version': mcpProtocolVersion,
          'Mcp-Session-Id': ?_session,
        },
        body: body,
      );
      if (res.statusCode >= 400 && res.statusCode != 405) {
        // Some servers don't care for notifications; tools still work.
      }
    } catch (_) {}
  }

  Future<void> _openLegacy() async {
    final req = http.Request('GET', Uri.parse(url))
      ..headers.addAll({..._auth, 'Accept': 'text/event-stream'});
    final res = await _client.send(req).timeout(const Duration(seconds: 20));
    if (res.statusCode >= 400) {
      final text = await res.stream.bytesToString();
      throw McpException(
        _errorText(res.statusCode, text),
        statusCode: res.statusCode,
        authenticate: res.headers['www-authenticate'],
      );
    }
    final endpoint = Completer<Uri>();
    _legacy = true;
    _legacySub = parseSseEvents(res.stream).listen(
      (e) {
        if (e.event == 'endpoint' && !endpoint.isCompleted) {
          endpoint.complete(Uri.parse(url).resolve(e.data.trim()));
          return;
        }
        try {
          final json = jsonDecode(e.data);
          if (json is Map<String, dynamic> && json['id'] is int) {
            _waiting.remove(json['id'])?.complete(json);
          }
        } catch (_) {}
      },
      onError: (Object e) {
        if (!endpoint.isCompleted) endpoint.completeError(e);
        for (final w in _waiting.values) {
          if (!w.isCompleted) w.completeError(e);
        }
        _waiting.clear();
      },
      onDone: () {
        if (!endpoint.isCompleted) {
          endpoint.completeError(McpException('The MCP server closed.'));
        }
        for (final w in _waiting.values) {
          if (!w.isCompleted) {
            w.completeError(McpException('The MCP server closed.'));
          }
        }
        _waiting.clear();
        _ready = false;
        _legacy = false;
      },
    );
    _postUrl = await endpoint.future.timeout(const Duration(seconds: 20));
  }

  Future<Map<String, dynamic>> _legacyRequest(
    int id,
    Map<String, dynamic> body,
    Duration timeout,
  ) async {
    final wait = _waiting[id] = Completer<Map<String, dynamic>>();
    final res = await _client.post(
      _postUrl!,
      headers: {..._auth, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (res.statusCode >= 400) {
      _waiting.remove(id);
      throw McpException(
        _errorText(res.statusCode, res.body),
        statusCode: res.statusCode,
        authenticate: res.headers['www-authenticate'],
      );
    }
    return _result(await wait.future.timeout(timeout));
  }

  void close() {
    _legacySub?.cancel();
    if (_session != null && !_legacy) {
      // Let the server free the session; never wait on it.
      unawaited(
        _client
            .delete(
              Uri.parse(url),
              headers: {..._auth, 'Mcp-Session-Id': _session!},
            )
            .then((_) {}, onError: (_) {})
            .whenComplete(() {
              if (_ownsClient) _client.close();
            }),
      );
      return;
    }
    if (_ownsClient) _client.close();
  }
}

String _errorText(int status, String body) {
  try {
    final json = jsonDecode(body);
    if (json is Map) {
      final e = json['error'];
      if (e is Map && e['message'] != null) return '${e['message']}';
      if (json['error_description'] != null) {
        return '${json['error_description']}';
      }
      if (e is String) return e;
    }
  } catch (_) {}
  return switch (status) {
    401 => 'The MCP server wants you to sign in.',
    403 => 'The MCP server refused access.',
    404 => 'Nothing at that address. Check the MCP server URL.',
    _ =>
      body.trim().isNotEmpty && body.length < 300
          ? body.trim()
          : 'The MCP server answered $status',
  };
}

/// A tool result's content as text: text parts as they are, the rest
/// described.
String mcpResultText(Map<String, dynamic> result) {
  final parts = <String>[];
  for (final c in (result['content'] as List? ?? const []).whereType<Map>()) {
    switch (c['type']) {
      case 'text':
        parts.add('${c['text'] ?? ''}');
      case 'image':
        parts.add('[An image (${c['mimeType'] ?? 'image'})]');
      case 'audio':
        parts.add('[Audio (${c['mimeType'] ?? 'audio'})]');
      case 'resource_link':
        parts.add('[${c['name'] ?? 'Link'}](${c['uri']})');
      case 'resource':
        final r = c['resource'];
        if (r is Map && r['text'] != null) {
          parts.add('${r['text']}');
        } else if (r is Map) {
          parts.add('[${r['uri']}]');
        }
    }
  }
  if (parts.isEmpty && result['structuredContent'] != null) {
    parts.add(jsonEncode(result['structuredContent']));
  }
  return parts.join('\n');
}

// ---- Sign-in (OAuth 2.1, as MCP servers do it) ----

/// Where and how to sign in to an MCP server.
class McpAuthServer {
  const McpAuthServer({
    required this.authorize,
    required this.token,
    this.register,
    this.scopes = const [],
    this.resource,
  });
  final Uri authorize;
  final Uri token;
  final Uri? register;
  final List<String> scopes;
  final String? resource;
}

/// Finds the server's sign-in from [authenticate] (its WWW-Authenticate
/// header) or the well-known addresses.
Future<McpAuthServer> discoverMcpAuth(
  String serverUrl, {
  String? authenticate,
  http.Client? httpClient,
}) async {
  final client = EncryptedOnlyClient(httpClient);
  try {
    final base = Uri.parse(serverUrl);
    Future<Map?> getJson(Uri u) async {
      try {
        final r = await client
            .get(u, headers: {'Accept': 'application/json'})
            .timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) return null;
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        return j is Map ? j : null;
      } catch (_) {
        return null;
      }
    }

    final hint = RegExp(r'resource_metadata="([^"]+)"')
        .firstMatch(authenticate ?? '')?[1];
    final scopeHint = RegExp(r'scope="([^"]+)"')
        .firstMatch(authenticate ?? '')?[1];
    final path = base.path == '/' ? '' : base.path;
    Map? resource;
    for (final u in [
      if (hint != null) base.resolve(hint),
      base.replace(path: '/.well-known/oauth-protected-resource$path'),
      base.replace(path: '/.well-known/oauth-protected-resource'),
    ]) {
      resource = await getJson(u);
      if (resource != null) break;
    }
    final issuer = Uri.parse(
      '${(resource?['authorization_servers'] as List?)?.firstOrNull ?? base.replace(path: '', query: '')}',
    );
    final ipath = issuer.path == '/' ? '' : issuer.path;
    Map? meta;
    for (final u in [
      issuer.replace(path: '/.well-known/oauth-authorization-server$ipath'),
      issuer.replace(path: '/.well-known/openid-configuration$ipath'),
      if (ipath.isNotEmpty)
        issuer.replace(path: '$ipath/.well-known/openid-configuration'),
    ]) {
      meta = await getJson(u);
      if (meta != null) break;
    }
    Uri at(String key, String fallback) => meta?[key] is String
        ? Uri.parse(meta![key] as String)
        : issuer.replace(path: fallback);
    final scopes = [
      if (scopeHint != null)
        ...scopeHint.split(' ')
      else
        for (final s in (resource?['scopes_supported'] as List? ?? const []))
          '$s',
    ];
    return McpAuthServer(
      authorize: at('authorization_endpoint', '/authorize'),
      token: at('token_endpoint', '/token'),
      register: meta == null || meta['registration_endpoint'] is String
          ? at('registration_endpoint', '/register')
          : null,
      scopes: scopes,
      resource: resource?['resource'] as String? ?? serverUrl,
    );
  } finally {
    if (httpClient == null) client.close();
  }
}

/// Registers the app with the sign-in server (dynamic client
/// registration): its client id, and a secret when the server gives one.
Future<({String id, String? secret})> registerMcpClient(
  Uri register,
  String redirect, {
  http.Client? httpClient,
}) async {
  final client = EncryptedOnlyClient(httpClient);
  try {
    final r = await client
        .post(
          register,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'client_name': 'OpenAide',
            'redirect_uris': [redirect],
            'grant_types': ['authorization_code', 'refresh_token'],
            'response_types': ['code'],
            'token_endpoint_auth_method': 'none',
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode >= 400) {
      throw McpException(
        "This server doesn't let apps sign up on their own "
        '(${_errorText(r.statusCode, r.body)}). Add a client ID for it.',
      );
    }
    final j = jsonDecode(r.body) as Map;
    return (id: '${j['client_id']}', secret: j['client_secret'] as String?);
  } finally {
    if (httpClient == null) client.close();
  }
}

/// Tokens from the sign-in server.
class McpTokens {
  const McpTokens(this.access, {this.refresh, this.expires});
  final String access;
  final String? refresh;
  final DateTime? expires;

  bool get expired =>
      expires != null &&
      DateTime.now().isAfter(expires!.subtract(const Duration(minutes: 1)));

  factory McpTokens.fromResponse(Map j, {String? oldRefresh}) => McpTokens(
    '${j['access_token']}',
    refresh: j['refresh_token'] as String? ?? oldRefresh,
    expires: j['expires_in'] is num
        ? DateTime.now().add(
            Duration(seconds: (j['expires_in'] as num).toInt()),
          )
        : null,
  );
}

/// Trades a code (or a refresh token) for tokens.
Future<McpTokens> mcpToken(
  Uri tokenUrl,
  Map<String, String> form, {
  String? clientSecret,
  http.Client? httpClient,
}) async {
  final client = EncryptedOnlyClient(httpClient);
  try {
    final r = await client
        .post(
          tokenUrl,
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': 'application/json',
          },
          body: {...form, 'client_secret': ?clientSecret},
        )
        .timeout(const Duration(seconds: 20));
    Object? j;
    try {
      j = jsonDecode(r.body);
    } on FormatException {
      j = Uri.splitQueryString(r.body);
    }
    if (r.statusCode >= 400 || j is! Map || j['access_token'] == null) {
      throw McpException(
        j is Map && j['error_description'] != null
            ? '${j['error_description']}'
            : 'Sign-in failed (${r.statusCode}).',
      );
    }
    return McpTokens.fromResponse(j, oldRefresh: form['refresh_token']);
  } finally {
    if (httpClient == null) client.close();
  }
}
