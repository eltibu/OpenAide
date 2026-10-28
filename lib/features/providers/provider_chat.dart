/// Replies from an AI provider's model, for a chat in Open WebUI's shape:
/// shared by the server chat (a provider model picked there) and chats
/// without a server.
library;

import 'dart:convert';

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
  final parsed = parseProviderModel(modelId);
  if (parsed == null) throw AiException('$modelId is not a provider model.');
  // Models on the phone need no key.
  final key = parsed.provider == AiProvider.local ? '' : keys[parsed.provider];
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
  yield* streamProviderReply(
    provider: parsed.provider,
    key: key,
    model: parsed.model,
    messages: messages,
    system: system,
    params: _providerParams(params),
  );
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
