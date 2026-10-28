/// Your MCP servers in chats: connecting (with a key or a sign-in), their
/// tools as agent tools, and signing in through the browser.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:url_launcher/url_launcher.dart';

import '../../core/agent/agent_loop.dart';
import '../../core/agent/mcp_client.dart';
import '../../core/ai/ai_providers.dart' show newCodeVerifier, codeChallenge;
import 'agent_store.dart';

/// A short, safe prefix for a server's tools ("github", "notion").
String serverSlug(Map server) {
  var raw = '${server['name'] ?? ''}'.trim();
  if (raw.isEmpty) raw = Uri.tryParse('${server['url']}')?.host ?? '';
  var s = raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (s.isEmpty) s = 'mcp';
  return s.length > 20 ? s.substring(0, 20) : s;
}

/// The headers you added for [server] ("Name: value" lines).
Map<String, String> serverHeaders(Map server) {
  final h = server['headers'];
  if (h is Map) return {for (final e in h.entries) '${e.key}': '${e.value}'};
  return {};
}

/// Connections kept open between replies, so tools aren't listed again
/// every message.
class McpPool {
  McpPool(this.store);
  final AgentStore store;

  final _clients = <String, McpClient>{};
  final _tools = <String, (DateTime, List<McpTool>)>{};
  final _keys = <String, String>{};

  /// The tools of every switched-on server that answered, and what went
  /// wrong with the others (by name).
  Future<({List<AgentTool> tools, Map<String, String> problems})> tools(
    AgentConfig config,
  ) async {
    final out = <AgentTool>[];
    final problems = <String, String>{};
    final servers = [
      for (final s in config.mcpServers)
        if (s['enabled'] != false) s,
    ];
    final results = await Future.wait([
      for (final s in servers)
        _toolsOf(s, config).then<Object>((t) => t, onError: (Object e) => e),
    ]);
    final used = <String>{};
    for (final (i, s) in servers.indexed) {
      final r = results[i];
      if (r is! List<McpTool>) {
        problems['${s['name'] ?? s['url']}'] = '$r';
        continue;
      }
      final slug = serverSlug(s);
      final off = {...?(s['off_tools'] as List?)?.map((e) => '$e')};
      for (final t in r) {
        if (off.contains(t.name)) continue;
        final base = toolName('${slug}__${t.name}');
        var name = base;
        // A number on the end, with room kept for it within 64 letters.
        for (var n = 2; !used.add(name); n++) {
          final end = '_$n';
          name =
              '${base.length + end.length > 64 ? base.substring(0, 64 - end.length) : base}$end';
        }
        out.add(
          AgentTool(
            name: name,
            description:
                '${t.description.isEmpty ? (t.title ?? t.name) : t.description}'
                ' (from ${s['name'] ?? slug})',
            parameters: _objectSchema(t.inputSchema),
            label: '${s['name'] ?? slug}: ${t.title ?? t.name}',
            run: (args) => _call(s, t.name, args),
          ),
        );
      }
    }
    return (tools: out, problems: problems);
  }

  /// Lists [server]'s tools fresh, for its page in settings.
  Future<List<McpTool>> listNow(Map server) async {
    _forget('${server['id']}');
    return _toolsOf(server, await store.current());
  }

  Future<List<McpTool>> _toolsOf(Map server, AgentConfig config) async {
    final id = '${server['id']}';
    final key = jsonEncode([
      server['url'],
      server['auth'],
      server['headers'],
      config.secretFor(id)['key'],
      config.secretFor(id)['access'],
    ]);
    if (_keys[id] != key) _forget(id);
    _keys[id] = key;
    final cached = _tools[id];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 15)) {
      return cached.$2;
    }
    final list = await _withAuth(server, (c) => c.listTools());
    _tools[id] = (DateTime.now(), list);
    return list;
  }

  Future<String> _call(
    Map server,
    String name,
    Map<String, dynamic> args,
  ) async {
    final r = await _withAuth(server, (c) => c.callTool(name, args));
    return r.isError ? 'Error: ${r.text}' : r.text;
  }

  void _forget(String id) {
    _clients.remove(id)?.close();
    _tools.remove(id);
  }

  Future<T> _withAuth<T>(Map server, Future<T> Function(McpClient) run) async {
    final id = '${server['id']}';
    final config = await store.current();
    var secret = config.secretFor(id);
    if (server['auth'] == 'oauth' && secret['access'] == null) {
      throw McpException(
        'Sign in to ${server['name'] ?? 'this server'} in '
        'Tools and skills first.',
      );
    }
    if (server['auth'] == 'oauth' && _expired(secret)) {
      secret = await _refresh(id, secret);
    }
    final client = _clients[id] ??= McpClient(
      '${server['url']}',
      token: server['auth'] == 'key'
          ? secret['key'] as String?
          : server['auth'] == 'oauth'
          ? secret['access'] as String?
          : null,
      headers: serverHeaders(server),
    );
    try {
      return await run(client);
    } on McpException catch (e) {
      if (!e.needsSignIn || server['auth'] != 'oauth') rethrow;
      // The token ran out early: refresh once and try again.
      _forget(id);
      final fresh = await _refresh(id, secret);
      final again = _clients[id] = McpClient(
        '${server['url']}',
        token: fresh['access'] as String?,
        headers: serverHeaders(server),
      );
      return run(again);
    }
  }

  bool _expired(Map secret) {
    final at = secret['expires'];
    return at is int && DateTime.now().millisecondsSinceEpoch > at - 60 * 1000;
  }

  Future<Map<String, dynamic>> _refresh(String id, Map secret) async {
    final refresh = secret['refresh'] as String?;
    final tokenUrl = secret['token_url'] as String?;
    if (refresh == null || tokenUrl == null) {
      throw McpException(
        'Your sign-in ran out. Sign in again in Tools and '
        'skills.',
        statusCode: 401,
      );
    }
    final t = await mcpToken(Uri.parse(tokenUrl), {
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
      'client_id': '${secret['client_id']}',
      if (secret['resource'] != null) 'resource': '${secret['resource']}',
    }, clientSecret: secret['client_secret'] as String?);
    final next = {...secret.cast<String, dynamic>(), ...tokenSecret(t)};
    await store.setSecretFor(id, next);
    return next;
  }

  void closeAll() {
    for (final c in _clients.values) {
      c.close();
    }
    _clients.clear();
    _tools.clear();
  }
}

Map<String, dynamic> tokenSecret(McpTokens t) => {
  'access': t.access,
  'refresh': ?t.refresh,
  'expires': ?t.expires?.millisecondsSinceEpoch,
};

/// Every provider wants an object with properties.
Map<String, dynamic> _objectSchema(Map<String, dynamic> s) => {
  ...s,
  'type': 'object',
  'properties': s['properties'] is Map ? s['properties'] : <String, dynamic>{},
};

/// Signs in to an MCP server in the browser (OAuth with PKCE), with the
/// app listening on the phone itself for the answer. Returns what to keep
/// in the keystore.
Future<Map<String, dynamic>> signInToMcp(
  Map server, {
  String? clientId,
  String? clientSecret,
}) async {
  // Ask the server first: its 401 says where to sign in.
  String? authenticate;
  final probe = McpClient('${server['url']}', headers: serverHeaders(server));
  var open = false;
  try {
    await probe.listTools();
    open = true;
  } on McpException catch (e) {
    if (e.needsSignIn) authenticate = e.authenticate;
  } catch (_) {
    // Unreachable or odd: the sign-in addresses may still work.
  } finally {
    probe.close();
  }
  if (open) {
    throw McpException(
      "This server doesn't need a sign-in. Pick \"No sign-in\" instead.",
    );
  }
  final auth = await discoverMcpAuth(
    '${server['url']}',
    authenticate: authenticate,
  );
  final listen = await _Loopback.start();
  try {
    final redirect = 'http://localhost:${listen.port}/callback';
    var id = clientId?.trim() ?? '';
    var secret = clientSecret?.trim();
    if (id.isEmpty) {
      if (auth.register == null) {
        throw McpException(
          "This server doesn't let apps sign up on their "
          'own. Add a client ID for it.',
        );
      }
      final reg = await registerMcpClient(auth.register!, redirect);
      id = reg.id;
      secret = reg.secret;
    }
    final verifier = newCodeVerifier(Random.secure());
    final state = newCodeVerifier(Random.secure()).substring(0, 16);
    final url = auth.authorize.replace(
      queryParameters: {
        ...auth.authorize.queryParameters,
        'response_type': 'code',
        'client_id': id,
        'redirect_uri': redirect,
        'code_challenge': codeChallenge(verifier),
        'code_challenge_method': 'S256',
        'state': state,
        if (auth.scopes.isNotEmpty) 'scope': auth.scopes.join(' '),
        'resource': ?auth.resource,
      },
    );
    if (!await launchUrl(url, mode: LaunchMode.inAppBrowserView) &&
        !await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw McpException("Couldn't open the browser.");
    }
    final back = await listen.result.timeout(
      const Duration(minutes: 10),
      onTimeout: () => throw McpException('Sign-in took too long.'),
    );
    if (back['state'] != state) {
      throw McpException(
        'Sign-in was mixed up. '
        'Try again.',
      );
    }
    final code = back['code'];
    if (code == null || code.isEmpty) {
      throw McpException(
        back['error_description'] ?? back['error'] ?? 'Sign-in was cancelled.',
      );
    }
    final tokens = await mcpToken(auth.token, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirect,
      'client_id': id,
      'code_verifier': verifier,
      'resource': ?auth.resource,
    }, clientSecret: secret);
    return {
      ...tokenSecret(tokens),
      'client_id': id,
      'client_secret': ?secret,
      'token_url': '${auth.token}',
      'resource': ?auth.resource,
    };
  } finally {
    listen.close();
  }
}

/// Waits on localhost for the browser to come back from a sign-in.
class _Loopback {
  _Loopback._(this._servers);
  final List<HttpServer> _servers;
  final _done = Completer<Map<String, String>>();

  int get port => _servers.first.port;
  Future<Map<String, String>> get result => _done.future;

  static Future<_Loopback> start() async {
    final v4 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final servers = [v4];
    try {
      servers.add(await HttpServer.bind(InternetAddress.loopbackIPv6, v4.port));
    } catch (_) {}
    final l = _Loopback._(servers);
    for (final s in servers) {
      s.listen(l._onRequest, onError: (_) {});
    }
    return l;
  }

  Future<void> _onRequest(HttpRequest req) async {
    if (req.uri.path != '/callback' || _done.isCompleted) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final q = req.uri.queryParameters;
    final ok = q['code'] != null;
    req.response.headers.contentType = ContentType.html;
    req.response.write(
      '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<style>body{font-family:sans-serif;max-width:28rem;margin:4rem auto;'
      'padding:0 1.5rem;text-align:center}a{display:inline-block;'
      'margin-top:1.5rem;padding:.8rem 1.6rem;border-radius:2rem;'
      'background:#0d6e66;color:#fff;text-decoration:none}</style></head>'
      '<body><h1>${ok ? 'Signed in' : 'Not signed in'}</h1><p>'
      '${ok ? 'You can go back to OpenAide now.' : 'The sign-in was cancelled.'}'
      '</p><a href="intent://#Intent;package=com.nexus.nexus_assistant;end">'
      'Back to OpenAide</a></body></html>',
    );
    await req.response.close();
    _done.complete(q);
  }

  void close() {
    for (final s in _servers) {
      s.close(force: true);
    }
  }
}
