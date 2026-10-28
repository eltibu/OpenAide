import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_assistant/core/ai/ai_providers.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/providers/provider_chat.dart';

http.StreamedResponse _sse(List<Object> events, {int status = 200}) =>
    http.StreamedResponse(
      Stream.value(
        utf8.encode(
          [for (final e in events) 'data: ${jsonEncode(e)}\n\n'].join(),
        ),
      ),
      status,
    );

void main() {
  test('provider model ids round-trip and never match server ids', () {
    final id = providerModelId(AiProvider.openRouter, 'anthropic/claude:beta');
    expect(id, 'direct:openrouter:anthropic/claude:beta');
    final parsed = parseProviderModel(id)!;
    expect(parsed.provider, AiProvider.openRouter);
    expect(parsed.model, 'anthropic/claude:beta');
    expect(isProviderModel('llama3:8b'), isFalse);
    expect(isProviderModel('nexus'), isFalse);
    expect(isProviderModel('direct:nobody:x'), isFalse);
  });

  test('OpenAI-style body carries photos as image parts', () {
    final body = openAiBody('gpt', const [
      AiMessage('user', 'What is this?', images: ['data:image/png;base64,AA']),
      AiMessage('assistant', ''),
    ], system: 'Be brief');
    final messages = body['messages'] as List;
    expect(messages, hasLength(2)); // the empty reply is left out
    expect(messages.first, {'role': 'system', 'content': 'Be brief'});
    final parts = (messages[1] as Map)['content'] as List;
    expect(parts.last, {
      'type': 'image_url',
      'image_url': {'url': 'data:image/png;base64,AA'},
    });
    expect(body['stream'], isTrue);
  });

  test('Claude body uses system, base64 images and max_tokens', () {
    final body = anthropicBody('claude-x', const [
      AiMessage('user', 'Hi', images: ['data:image/jpeg;base64,QUJD']),
    ], system: 'Sys');
    expect(body['system'], 'Sys');
    expect(body['max_tokens'], 8192);
    final content = ((body['messages'] as List).single as Map)['content'];
    expect((content as List).first, {
      'type': 'image',
      'source': {'type': 'base64', 'media_type': 'image/jpeg', 'data': 'QUJD'},
    });
  });

  test('streams OpenRouter text and reasoning', () async {
    late http.BaseRequest sent;
    final client = MockClient.streaming((req, _) async {
      sent = req;
      return _sse([
        {
          'choices': [
            {
              'delta': {'reasoning': 'Hmm. '},
            },
          ],
        },
        {
          'choices': [
            {
              'delta': {'content': 'Hello'},
            },
          ],
        },
        {
          'choices': [
            {
              'delta': {'content': ' there'},
            },
          ],
        },
      ]);
    });
    final chunks = await streamProviderReply(
      provider: AiProvider.openRouter,
      key: 'sk-or-1',
      model: 'openai/gpt-x',
      messages: const [AiMessage('user', 'Hi')],
      httpClient: client,
    ).toList();
    expect(
      sent.url.toString(),
      'https://openrouter.ai/api/v1/chat/completions',
    );
    expect(sent.headers['Authorization'], 'Bearer sk-or-1');
    expect(chunks.map((c) => c.text).join(), 'Hello there');
    expect(chunks.map((c) => c.thinking).join(), 'Hmm. ');
  });

  test('streams Claude text and thinking', () async {
    late http.BaseRequest sent;
    final client = MockClient.streaming((req, _) async {
      sent = req;
      return _sse([
        {'type': 'message_start'},
        {
          'type': 'content_block_delta',
          'delta': {'type': 'thinking_delta', 'thinking': 'Let me see.'},
        },
        {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'Hi!'},
        },
        {'type': 'message_stop'},
      ]);
    });
    final chunks = await streamProviderReply(
      provider: AiProvider.anthropic,
      key: 'sk-ant-1',
      model: 'claude-x',
      messages: const [AiMessage('user', 'Hi')],
      httpClient: client,
    ).toList();
    expect(sent.url.toString(), 'https://api.anthropic.com/v1/messages');
    expect(sent.headers['x-api-key'], 'sk-ant-1');
    expect(sent.headers['anthropic-version'], isNotEmpty);
    expect(chunks.map((c) => c.text).join(), 'Hi!');
    expect(chunks.map((c) => c.thinking).join(), 'Let me see.');
  });

  test("a refused key reports the provider's message", () async {
    final client = MockClient.streaming(
      (_, _) async => http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'error': {'message': 'invalid x-api-key'},
            }),
          ),
        ),
        401,
      ),
    );
    expect(
      streamProviderReply(
        provider: AiProvider.anthropic,
        key: 'bad',
        model: 'claude-x',
        messages: const [AiMessage('user', 'Hi')],
        httpClient: client,
      ).toList(),
      throwsA(
        isA<AiException>().having(
          (e) => e.message,
          'message',
          'invalid x-api-key',
        ),
      ),
    );
  });

  test('lists OpenAI chat models only', () async {
    final client = MockClient((req) async {
      expect(req.url.toString(), 'https://api.openai.com/v1/models');
      expect(req.headers['Authorization'], 'Bearer sk-1');
      return http.Response(
        jsonEncode({
          'data': [
            for (final id in [
              'gpt-5',
              'gpt-4o-mini-tts',
              'text-embedding-3-small',
              'o3',
              'dall-e-3',
              'gpt-realtime',
              'whisper-1',
            ])
              {'id': id},
          ],
        }),
        200,
      );
    });
    final models = await listProviderModels(
      AiProvider.openAi,
      'sk-1',
      httpClient: client,
    );
    expect(models.map((m) => m.id), [
      'direct:openai:o3',
      'direct:openai:gpt-5',
    ]);
    expect(models.first.raw['nexus_provider'], 'openai');
  });

  test('lists OpenRouter models only when the key works', () async {
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/key')) {
        return http.Response(
          jsonEncode({
            'error': {'message': 'No auth credentials found'},
          }),
          401,
        );
      }
      return http.Response(jsonEncode({'data': []}), 200);
    });
    expect(
      listProviderModels(AiProvider.openRouter, 'bad', httpClient: client),
      throwsA(isA<AiException>()),
    );
  });

  test('PKCE challenge is the S256 of the verifier', () {
    // RFC 7636 appendix B.
    expect(
      codeChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
    final url = openRouterAuthUrl(
      callback: 'http://localhost:1234/callback',
      verifier: 'v',
    );
    expect(url.queryParameters['code_challenge_method'], 'S256');
    expect(
      url.queryParameters['callback_url'],
      'http://localhost:1234/callback',
    );
  });

  test('exchanges the OpenRouter code for a key', () async {
    final client = MockClient((req) async {
      expect(req.url.toString(), 'https://openrouter.ai/api/v1/auth/keys');
      final body = jsonDecode(req.body) as Map;
      expect(body['code'], 'c1');
      expect(body['code_verifier'], 'v1');
      return http.Response(jsonEncode({'key': 'sk-or-new'}), 200);
    });
    expect(
      await exchangeOpenRouterCode('c1', 'v1', httpClient: client),
      'sk-or-new',
    );
  });

  test('a chat reply asks for a missing key by name', () {
    expect(
      streamDirectReply(
        keys: const {},
        modelId: 'direct:anthropic:claude-x',
        history: [ChatMessage(id: '1', role: 'user', content: 'Hi')],
      ).toList(),
      throwsA(
        isA<AiException>().having(
          (e) => e.message,
          'message',
          contains('Claude key'),
        ),
      ),
    );
  });

  test('thinking becomes a reasoning step before the text', () {
    final out = directOutput('Answer', 'Because', done: true);
    expect(out.first['type'], 'reasoning');
    expect(out.first['status'], 'completed');
    expect(out.last['type'], 'message');
    expect(directOutput('Answer', '', done: true), hasLength(1));
  });
}
