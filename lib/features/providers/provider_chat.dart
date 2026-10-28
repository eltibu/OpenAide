/// Replies from an AI provider's model, for a chat in Open WebUI's shape:
/// shared by the server chat (a provider model picked there) and chats
/// without a server.
library;

import 'dart:convert';

import '../../core/agent/agent_loop.dart';
import '../../core/ai/ai_providers.dart';
import '../../core/models/chat.dart';

/// Streams [modelId]'s reply to [history] (oldest first). [imageBytes]
/// fetches a photo that isn't inline (a server file); without it, such
/// photos are left out.
Stream<AiChunk> streamDirectReply({
  required Map<AiProvider, String> keys,
  required String modelId,
  required List<ChatMessage> history,
  String? system,
  Map<String, dynamic> params = const {},
  Future<List<int>> Function(Attachment)? imageBytes,
}) async* {
  final (provider, key, model, messages) = await _prepare(
    keys,
    modelId,
    history,
    imageBytes,
  );
  yield* streamProviderReply(
    provider: provider,
    key: key,
    model: model,
    messages: messages,
    system: system,
    params: _providerParams(params),
  );
}

/// Models that can't call tools themselves (small ones on the phone): they
/// get the tools in their instructions instead.
bool usesPromptTools(AiProvider p) => p.id == 'local';

/// [modelId]'s reply to [history] with [tools]: the model may call them
/// as many times as it needs before answering.
Stream<AgentEvent> streamAgentReply({
  required Map<AiProvider, String> keys,
  required String modelId,
  required List<ChatMessage> history,
  required List<AgentTool> tools,
  String? system,
  Map<String, dynamic> params = const {},
  Future<List<int>> Function(Attachment)? imageBytes,
}) async* {
  final (provider, key, model, messages) = await _prepare(
    keys,
    modelId,
    history,
    imageBytes,
  );
  final p = _providerParams(params);
  yield* runAgent(
    messages: messages,
    system: system,
    tools: tools,
    nativeTools: !usesPromptTools(provider),
    turn: ({required messages, system, required tools, required turns}) =>
        streamProviderReply(
          provider: provider,
          key: key,
          model: model,
          messages: messages,
          system: system,
          params: p,
          tools: tools,
          turns: turns,
        ),
  );
}

Future<(AiProvider, String, String, List<AiMessage>)> _prepare(
  Map<AiProvider, String> keys,
  String modelId,
  List<ChatMessage> history,
  Future<List<int>> Function(Attachment)? imageBytes,
) async {
  final parsed = parseProviderModel(modelId);
  if (parsed == null) throw AiException('$modelId is not a provider model.');
  final key =
      keys[parsed.provider] ?? (usesPromptTools(parsed.provider) ? '' : null);
  if (key == null) {
    throw AiException(
      'Add your ${parsed.provider.label} key in Settings > AI providers '
      'to use this model.',
    );
  }
  final messages = <AiMessage>[
    for (final m in history)
      if (m.role == 'user' || m.role == 'assistant')
        AiMessage(
          m.role,
          m.content,
          images: [
            for (final a in attachmentsOf(m))
              if (a.isImage) ?await _imageUrl(a, imageBytes),
          ],
        ),
  ];
  return (parsed.provider, key, parsed.model, messages);
}

List<Attachment> attachmentsOf(ChatMessage m) => [
  for (final f in (m.extra['files'] as List? ?? const []).whereType<Map>())
    Attachment.fromJson(f.cast<String, dynamic>()),
];

Future<String?> _imageUrl(
  Attachment a,
  Future<List<int>> Function(Attachment)? imageBytes,
) async {
  if (a.dataUrl != null) return a.dataUrl;
  if (imageBytes == null) return null;
  try {
    final bytes = await imageBytes(a);
    final type = (a.contentType ?? 'image/jpeg').split(';').first;
    return 'data:$type;base64,${base64Encode(bytes)}';
  } catch (_) {
    return null;
  }
}

/// The chat's model settings providers understand; the rest (Open WebUI's
/// own, such as function calling mode) stay out of the request.
Map<String, dynamic> _providerParams(Map<String, dynamic> params) => {
  for (final k in const [
    'temperature',
    'top_p',
    'max_tokens',
    'frequency_penalty',
    'presence_penalty',
    'seed',
    'stop',
    'reasoning_effort',
  ])
    if (params[k] != null) k: params[k],
};

/// The reply as Open WebUI's `output` items, so thinking shows in its own
/// collapsible step, as for server replies.
List<Map<String, dynamic>> directOutput(
  String text,
  String thinking, {
  required bool done,
}) => [
  if (thinking.isNotEmpty)
    {
      'type': 'reasoning',
      'status': done || text.isNotEmpty ? 'completed' : 'in_progress',
      'content': [
        {'type': 'output_text', 'text': thinking},
      ],
    },
  {
    'type': 'message',
    'content': [
      {'type': 'output_text', 'text': text},
    ],
  },
];

/// Builds a reply's text and `output` items (thinking, tool calls and what
/// they returned, text) from the agent's events, so tool steps show in
/// the reply as they do for server replies.
class AgentOutput {
  final _items = <Map<String, dynamic>>[];
  final _text = StringBuffer();

  /// Every bit of text the model wrote, for the message's content.
  String get content => _text.toString();

  bool get hasSteps => _items.any((i) => i['type'] != 'message');

  void add(AgentEvent e) {
    switch (e) {
      case AgentThinking(:final text):
        final last = _items.lastOrNull;
        if (last != null && last['type'] == 'reasoning') {
          final c = (last['content'] as List).first as Map;
          c['text'] = '${c['text']}$text';
        } else {
          _items.add({
            'type': 'reasoning',
            'status': 'in_progress',
            'content': [
              {'type': 'output_text', 'text': text},
            ],
          });
        }
      case AgentText(:final text):
        _text.write(text);
        _closeThinking();
        final last = _items.lastOrNull;
        if (last != null && last['type'] == 'message') {
          final c = (last['content'] as List).first as Map;
          c['text'] = '${c['text']}$text';
        } else {
          _items.add({
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': text},
            ],
          });
        }
      case AgentToolStart(:final id, :final name, :final arguments):
        _closeThinking();
        // Text before a tool call reads as its own paragraph.
        if (_text.isNotEmpty && !content.endsWith('\n\n')) _text.write('\n\n');
        _items.add({
          'type': 'function_call',
          'call_id': id,
          'name': name,
          'arguments': arguments,
          'status': 'in_progress',
        });
      case AgentToolDone(:final id, :final output, :final failed):
        for (final i in _items) {
          if (i['type'] == 'function_call' && i['call_id'] == id) {
            i['status'] = failed ? 'failed' : 'completed';
          }
        }
        _items.add({
          'type': 'function_call_output',
          'call_id': id,
          'status': failed ? 'failed' : 'completed',
          'output': [
            {'type': 'input_text', 'text': output},
          ],
        });
    }
  }

  void _closeThinking() {
    for (final i in _items) {
      if (i['type'] == 'reasoning') i['status'] = 'completed';
    }
  }

  /// The items so far; [done] marks every step finished.
  List<Map<String, dynamic>> output({bool done = false}) {
    if (done) {
      _closeThinking();
      for (final i in _items) {
        if (i['status'] == 'in_progress') i['status'] = 'failed';
      }
    }
    return [
      for (final i in jsonDecode(jsonEncode(_items)) as List)
        (i as Map).cast<String, dynamic>(),
    ];
  }
}
