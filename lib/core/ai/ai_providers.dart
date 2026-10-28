/// AI providers the phone talks to itself, with no Open WebUI in between:
/// OpenRouter, Claude (Anthropic's API) and OpenAI. Each person
/// brings their own key; keys stay on the phone.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../api/sse.dart';
import 'copilot.dart';
import 'local_llm.dart';
import '../models/model_info.dart';

enum AiProvider {
  openRouter('openrouter', 'OpenRouter'),
  anthropic('anthropic', 'Claude'),
  openAi('openai', 'OpenAI'),
  copilot('copilot', 'GitHub Copilot'),

  /// Models downloaded to the phone (local_llm.dart); no key, no internet.
  local('local', 'On this phone');

  const AiProvider(this.id, this.label);

  /// Kept in model ids and in storage; never changes.
  final String id;
  final String label;

  static AiProvider? byId(String? id) =>
      AiProvider.values.where((p) => p.id == id).firstOrNull;
}

/// Model ids in the picker read `direct:<provider>:<the provider's id>`,
/// so they never clash with a server's models.
const _idPrefix = 'direct:';

String providerModelId(AiProvider p, String model) =>
    '$_idPrefix${p.id}:$model';

/// The provider and its own model id behind a picker id, or null for a
/// server model.
({AiProvider provider, String model})? parseProviderModel(String? id) {
  if (id == null || !id.startsWith(_idPrefix)) return null;
  final rest = id.substring(_idPrefix.length);
  final colon = rest.indexOf(':');
  if (colon <= 0) return null;
  final p = AiProvider.byId(rest.substring(0, colon));
  if (p == null) return null;
  return (provider: p, model: rest.substring(colon + 1));
}

bool isProviderModel(String? id) => parseProviderModel(id) != null;

class AiException implements Exception {
  AiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// One message as the provider reads it: text plus photos as data URLs.
class AiMessage {
  const AiMessage(this.role, this.text, {this.images = const []});
  final String role;
  final String text;
  final List<String> images;
}

/// A piece of a streaming reply.
class AiChunk {
  const AiChunk({this.text = '', this.thinking = '', this.tools = const []});
  final String text;
  final String thinking;

  /// Pieces of tool calls the model is making, by their place in the reply.
  final List<AiToolDelta> tools;
}

/// Part of a tool call as it streams: the first piece has its id and name,
/// the rest more of its arguments (JSON text).
class AiToolDelta {
  const AiToolDelta(this.index, {this.id, this.name, this.arguments = ''});
  final int index;
  final String? id;
  final String? name;
  final String arguments;
}

/// A tool the model may call: what it does and its arguments as JSON
/// Schema.
class AiToolSpec {
  const AiToolSpec(this.name, this.description, this.parameters);
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
}

/// One tool call the model made.
class AiToolCall {
  const AiToolCall(this.id, this.name, this.arguments);
  final String id;
  final String name;

  /// JSON text, as the model wrote it.
  final String arguments;
}

/// A step of the model using tools: what it said, the calls it made and
/// what each returned (same order). Sent back after the chat's messages.
class AiToolTurn {
  const AiToolTurn(this.text, this.calls, this.results);
  final String text;
  final List<AiToolCall> calls;
  final List<String> results;
}

const _openRouterBase = 'https://openrouter.ai/api/v1';
const _anthropicBase = 'https://api.anthropic.com/v1';
const _openAiBase = 'https://api.openai.com/v1';
const _anthropicVersion = '2023-06-01';

/// Where each provider hands out keys, for the "Get a key" links.
const providerKeyPages = {
  AiProvider.openRouter: 'https://openrouter.ai/settings/keys',
  AiProvider.anthropic: 'https://console.anthropic.com/settings/keys',
  AiProvider.openAi: 'https://platform.openai.com/api-keys',
  AiProvider.copilot: 'https://github.com/settings/copilot',
};

Map<String, String> _headers(AiProvider p, String key) => switch (p) {
  AiProvider.openRouter => {
    'Authorization': 'Bearer $key',
    // How OpenRouter names the app on its activity page.
    'HTTP-Referer': 'https://github.com/eltibu/nexus-assistant',
    'X-Title': 'OpenAide',
  },
  AiProvider.anthropic => {
    'x-api-key': key,
    'anthropic-version': _anthropicVersion,
  },
  AiProvider.openAi => {'Authorization': 'Bearer $key'},
  // Copilot's token comes from copilotSession; see copilot.dart.
  AiProvider.copilot => copilotHeaders(key),
  AiProvider.local => const {},
};

/// The provider's own words for what went wrong, else the status.
String _errorText(int status, String body) {
  try {
    final json = jsonDecode(body);
    if (json is Map) {
      final e = json['error'];
      if (e is Map && e['message'] != null) return '${e['message']}';
      if (e is String && e.isNotEmpty) return e;
      if (json['message'] != null) return '${json['message']}';
    }
  } catch (_) {}
  return switch (status) {
    401 || 403 => 'The key was refused. Check it and try again.',
    429 => 'Too many requests for now. Try again in a moment.',
    _ =>
      body.trim().isNotEmpty && body.length < 300
          ? body.trim()
          : 'It answered $status',
  };
}

Future<dynamic> _getJson(
  http.Client client,
  Uri url,
  Map<String, String> headers,
) async {
  final res = await client
      .get(url, headers: headers)
      .timeout(const Duration(seconds: 20));
  if (res.statusCode >= 400) {
    throw AiException(
      _errorText(res.statusCode, res.body),
      statusCode: res.statusCode,
    );
  }
  return jsonDecode(utf8.decode(res.bodyBytes));
}

ModelInfo _model(
  AiProvider p,
  String id,
  String name, {
  String? description,
  bool vision = false,
}) => ModelInfo.fromJson({
  'id': providerModelId(p, id),
  'name': name,
  'owned_by': p.label,
  'nexus_provider': p.id,
  'provider_model': id,
  'tags': [
    {'name': p.label},
  ],
  'info': {
    'meta': {
      'description': ?description,
      'capabilities': {'vision': vision},
    },
  },
});

/// Every chat model [key] can use at [p], as picker entries.
Future<List<ModelInfo>> listProviderModels(
  AiProvider p,
  String key, {
  http.Client? httpClient,
}) async {
  final client = httpClient ?? http.Client();
  try {
    switch (p) {
      case AiProvider.openRouter:
        // The list is public, so check the key separately.
        await _getJson(
          client,
          Uri.parse('$_openRouterBase/key'),
          _headers(p, key),
        );
        final json = await _getJson(
          client,
          Uri.parse('$_openRouterBase/models'),
          _headers(p, key),
        );
        return [
          for (final m
              in ((json as Map)['data'] as List? ?? const []).whereType<Map>())
            if (_outputsText(m['architecture']))
              _model(
                p,
                '${m['id']}',
                '${m['name'] ?? m['id']}',
                vision: _inputs(m['architecture']).contains('image'),
              ),
        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case AiProvider.anthropic:
        final json = await _getJson(
          client,
          Uri.parse('$_anthropicBase/models?limit=100'),
          _headers(p, key),
        );
        return [
          for (final m
              in ((json as Map)['data'] as List? ?? const []).whereType<Map>())
            _model(
              p,
              '${m['id']}',
              '${m['display_name'] ?? m['id']}',
              vision: true,
            ),
        ];
      case AiProvider.copilot:
        final session = await copilotSession(key, client);
        final json = await _getJson(
          client,
          Uri.parse('${session.base}/models'),
          copilotHeaders(session.token),
        );
        return [
          for (final m
              in ((json as Map)['data'] as List? ?? const []).whereType<Map>())
            if ((m['capabilities'] as Map?)?['type'] == 'chat' &&
                m['model_picker_enabled'] != false)
              _model(
                p,
                '${m['id']}',
                '${m['name'] ?? m['id']}',
                vision:
                    ((m['capabilities'] as Map?)?['supports']
                        as Map?)?['vision'] ==
                    true,
              ),
        ];
      case AiProvider.local:
        // Downloaded models are listed by the models screen's store.
        return const [];
      case AiProvider.openAi:
        final json = await _getJson(
          client,
          Uri.parse('$_openAiBase/models'),
          _headers(p, key),
        );
        final ids = [
          for (final m
              in ((json as Map)['data'] as List? ?? const []).whereType<Map>())
            '${m['id']}',
        ].where(isOpenAiChatModel).toList()..sort((a, b) => b.compareTo(a));
        return [
          for (final id in ids)
            _model(p, id, id, vision: !id.startsWith('gpt-3.5')),
        ];
    }
  } on AiException {
    rethrow;
  } on TimeoutException {
    throw AiException("${p.label} didn't answer in time.");
  } catch (e) {
    throw AiException("Couldn't reach ${p.label}: $e");
  } finally {
    if (httpClient == null) client.close();
  }
}

/// OpenAI lists every model it has (speech, images, embeddings...); only
/// chat models can answer here.
bool isOpenAiChatModel(String id) =>
    RegExp(r'^(gpt-|o\d|chatgpt-)').hasMatch(id) &&
    !RegExp(r'(audio|realtime|transcribe|tts|image|search|embedding|instruct)')
        .hasMatch(id);

List<String> _inputs(Object? architecture) => [
  for (final m
      in (architecture is Map
          ? architecture['input_modalities'] as List? ?? const []
          : const []))
    '$m',
];

bool _outputsText(Object? architecture) {
  if (architecture is! Map) return true;
  final out = architecture['output_modalities'];
  return out is! List || out.contains('text');
}

/// Streams [model]'s reply at [p] to [messages].
Stream<AiChunk> streamProviderReply({
  required AiProvider provider,
  required String key,
  required String model,
  required List<AiMessage> messages,
  String? system,
  Map<String, dynamic> params = const {},
  List<AiToolSpec> tools = const [],
  List<AiToolTurn> turns = const [],
  http.Client? httpClient,
}) async* {
  if (provider == AiProvider.local) {
    yield* streamLocalModel(
      file: model,
      messages: messages,
      system: system,
      params: params,
    );
    return;
  }
  final client = httpClient ?? http.Client();
  try {
    final http.Request req;
    var headers = _headers(provider, key);
    if (provider == AiProvider.copilot) {
      final session = await copilotSession(key, client);
      headers = copilotHeaders(session.token);
      req = http.Request('POST', Uri.parse('${session.base}/chat/completions'))
        ..body = jsonEncode(
          openAiBody(
            model,
            messages,
            system: system,
            params: params,
            tools: tools,
            turns: turns,
          ),
        );
    } else if (provider == AiProvider.anthropic) {
      req = http.Request('POST', Uri.parse('$_anthropicBase/messages'))
        ..body = jsonEncode(
          anthropicBody(
            model,
            messages,
            system: system,
            params: params,
            tools: tools,
            turns: turns,
          ),
        );
    } else {
      final base = provider == AiProvider.openRouter
          ? _openRouterBase
          : _openAiBase;
      req = http.Request('POST', Uri.parse('$base/chat/completions'))
        ..body = jsonEncode(
          openAiBody(
            model,
            messages,
            system: system,
            params: params,
            tools: tools,
            turns: turns,
          ),
        );
    }
    req.headers.addAll({
      ...headers,
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
    });
    final res = await client.send(req).timeout(const Duration(seconds: 60));
    if (res.statusCode == 401 && provider == AiProvider.copilot) {
      dropCopilotSession(key);
    }
    if (res.statusCode >= 400) {
      throw AiException(
        _errorText(res.statusCode, await res.stream.bytesToString()),
        statusCode: res.statusCode,
      );
    }
    await for (final event in parseSse(res.stream)) {
      final chunk = provider == AiProvider.anthropic
          ? anthropicChunk(event)
          : openAiChunk(event);
      if (chunk != null) yield chunk;
    }
  } on AiException {
    rethrow;
  } on TimeoutException {
    throw AiException("${provider.label} didn't answer in time.");
  } on http.ClientException catch (e) {
    throw AiException("Couldn't reach ${provider.label}: ${e.message}");
  } finally {
    if (httpClient == null) client.close();
  }
}

/// The request body for OpenAI-style chat (OpenRouter, OpenAI).
Map<String, dynamic> openAiBody(
  String model,
  List<AiMessage> messages, {
  String? system,
  Map<String, dynamic> params = const {},
  List<AiToolSpec> tools = const [],
  List<AiToolTurn> turns = const [],
}) => {
  ...params,
  'model': model,
  'stream': true,
  if (tools.isNotEmpty)
    'tools': [
      for (final t in tools)
        {
          'type': 'function',
          'function': {
            'name': t.name,
            'description': t.description,
            'parameters': t.parameters,
          },
        },
    ],
  'messages': [
    if (system != null && system.trim().isNotEmpty)
      {'role': 'system', 'content': system},
    for (final m in messages)
      if (m.text.isNotEmpty || m.images.isNotEmpty)
        {
          'role': m.role,
          'content': m.images.isEmpty
              ? m.text
              : [
                  if (m.text.isNotEmpty) {'type': 'text', 'text': m.text},
                  for (final url in m.images)
                    {
                      'type': 'image_url',
                      'image_url': {'url': url},
                    },
                ],
        },
    for (final turn in turns) ...[
      {
        'role': 'assistant',
        'content': turn.text.isEmpty ? null : turn.text,
        if (turn.calls.isNotEmpty)
          'tool_calls': [
            for (final c in turn.calls)
              {
                'id': c.id,
                'type': 'function',
                'function': {
                  'name': c.name,
                  'arguments': c.arguments.isEmpty ? '{}' : c.arguments,
                },
              },
          ],
      },
      for (final (i, c) in turn.calls.indexed)
        {
          'role': 'tool',
          'tool_call_id': c.id,
          'content': i < turn.results.length ? turn.results[i] : '',
        },
    ],
  ],
};

/// Arguments as an object, whatever the model wrote.
Map<String, dynamic> toolArguments(String json) {
  if (json.trim().isEmpty) return {};
  try {
    final v = jsonDecode(json);
    if (v is Map) return v.cast<String, dynamic>();
  } on FormatException {
    // Left empty below.
  }
  return {};
}

/// The request body for Claude's Messages API.
Map<String, dynamic> anthropicBody(
  String model,
  List<AiMessage> messages, {
  String? system,
  Map<String, dynamic> params = const {},
  List<AiToolSpec> tools = const [],
  List<AiToolTurn> turns = const [],
}) => {
  if (params['temperature'] != null) 'temperature': params['temperature'],
  if (params['top_p'] != null) 'top_p': params['top_p'],
  'model': model,
  'max_tokens': params['max_tokens'] ?? 8192,
  'stream': true,
  if (system != null && system.trim().isNotEmpty) 'system': system,
  if (tools.isNotEmpty)
    'tools': [
      for (final t in tools)
        {
          'name': t.name,
          'description': t.description,
          'input_schema': t.parameters,
        },
    ],
  'messages': [
    for (final m in messages)
      if (m.role != 'system' && (m.text.isNotEmpty || m.images.isNotEmpty))
        {
          'role': m.role == 'assistant' ? 'assistant' : 'user',
          'content': [
            for (final url in m.images) ?_anthropicImage(url),
            if (m.text.isNotEmpty) {'type': 'text', 'text': m.text},
          ],
        },
    for (final turn in turns) ...[
      {
        'role': 'assistant',
        'content': [
          if (turn.text.trim().isNotEmpty) {'type': 'text', 'text': turn.text},
          for (final c in turn.calls)
            {
              'type': 'tool_use',
              'id': c.id,
              'name': c.name,
              'input': toolArguments(c.arguments),
            },
        ],
      },
      if (turn.calls.isNotEmpty)
        {
          'role': 'user',
          'content': [
            for (final (i, c) in turn.calls.indexed)
              {
                'type': 'tool_result',
                'tool_use_id': c.id,
                'content': i < turn.results.length && turn.results[i].isNotEmpty
                    ? turn.results[i]
                    : '(no output)',
              },
          ],
        },
    ],
  ],
};

Map<String, dynamic>? _anthropicImage(String dataUrl) {
  final match = RegExp(r'^data:([^;,]+);base64,(.*)$').firstMatch(dataUrl);
  if (match == null) return null;
  return {
    'type': 'image',
    'source': {
      'type': 'base64',
      'media_type': match.group(1),
      'data': match.group(2),
    },
  };
}

AiChunk? openAiChunk(Map<String, dynamic> event) {
  final error = event['error'];
  if (error != null) {
    throw AiException(error is Map ? '${error['message'] ?? error}' : '$error');
  }
  final choices = event['choices'];
  if (choices is! List || choices.isEmpty) return null;
  final delta = (choices.first as Map)['delta'];
  if (delta is! Map) return null;
  final text = delta['content'];
  final thinking = delta['reasoning'] ?? delta['reasoning_content'];
  final calls = delta['tool_calls'];
  final tools = [
    for (final (i, c) in (calls is List ? calls : const []).indexed)
      if (c is Map)
        AiToolDelta(
          c['index'] is int ? c['index'] as int : i,
          id: c['id'] as String?,
          name: (c['function'] as Map?)?['name'] as String?,
          arguments: '${(c['function'] as Map?)?['arguments'] ?? ''}',
        ),
  ];
  if (text is! String && thinking is! String && tools.isEmpty) return null;
  return AiChunk(
    text: text is String ? text : '',
    thinking: thinking is String ? thinking : '',
    tools: tools,
  );
}

AiChunk? anthropicChunk(Map<String, dynamic> event) {
  switch (event['type']) {
    case 'error':
      final e = event['error'];
      throw AiException(e is Map ? '${e['message'] ?? e}' : '$e');
    case 'content_block_start':
      final block = event['content_block'];
      if (block is! Map || block['type'] != 'tool_use') return null;
      return AiChunk(
        tools: [
          AiToolDelta(
            event['index'] as int? ?? 0,
            id: '${block['id']}',
            name: '${block['name']}',
          ),
        ],
      );
    case 'content_block_delta':
      final delta = event['delta'];
      if (delta is! Map) return null;
      return switch (delta['type']) {
        'text_delta' => AiChunk(text: '${delta['text'] ?? ''}'),
        'thinking_delta' => AiChunk(thinking: '${delta['thinking'] ?? ''}'),
        'input_json_delta' => AiChunk(
          tools: [
            AiToolDelta(
              event['index'] as int? ?? 0,
              arguments: '${delta['partial_json'] ?? ''}',
            ),
          ],
        ),
        _ => null,
      };
  }
  return null;
}

// Sign in with OpenRouter (OAuth with PKCE): the person approves in the
// browser, and OpenRouter hands the app a key of their own.

String newCodeVerifier([Random? random]) {
  final r = random ?? Random.secure();
  return base64UrlEncode([for (var i = 0; i < 32; i++) r.nextInt(256)])
      .replaceAll('=', '');
}

String codeChallenge(String verifier) =>
    base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');

Uri openRouterAuthUrl({required String callback, required String verifier}) =>
    Uri.parse('https://openrouter.ai/auth').replace(
      queryParameters: {
        'callback_url': callback,
        'code_challenge': codeChallenge(verifier),
        'code_challenge_method': 'S256',
      },
    );

/// Trades the code OpenRouter sent back for the person's key.
Future<String> exchangeOpenRouterCode(
  String code,
  String verifier, {
  http.Client? httpClient,
}) async {
  final client = httpClient ?? http.Client();
  try {
    final res = await client
        .post(
          Uri.parse('$_openRouterBase/auth/keys'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'code': code,
            'code_verifier': verifier,
            'code_challenge_method': 'S256',
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode >= 400) {
      throw AiException(_errorText(res.statusCode, res.body));
    }
    final key = (jsonDecode(res.body) as Map)['key'];
    if (key is! String || key.isEmpty) {
      throw AiException("OpenRouter didn't send a key back.");
    }
    return key;
  } finally {
    if (httpClient == null) client.close();
  }
}
