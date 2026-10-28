import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_assistant/core/agent/agent_loop.dart';
import 'package:nexus_assistant/core/agent/calculator.dart';
import 'package:nexus_assistant/core/agent/mcp_client.dart';
import 'package:nexus_assistant/core/agent/skills.dart';
import 'package:nexus_assistant/core/agent/web_tools.dart';
import 'package:nexus_assistant/core/ai/ai_providers.dart';
import 'package:nexus_assistant/features/providers/provider_chat.dart';

void main() {
  group('calculator', () {
    test('works out arithmetic', () {
      expect(calculate('1 + 2 * 3'), 7);
      expect(calculate('(1 + 2) * 3'), 9);
      expect(calculate('2^10'), 1024);
      expect(calculate('-2^2'), -4);
      expect(calculate('50% * 200'), 100);
      expect(calculate('sqrt(16) + abs(-2)'), 6);
      expect(calculate('max(3, 9, 4)'), 9);
      expect(calculate('5!'), 120);
      expect(calculate('1,250 * 2'), 2500);
      expect(formatNumber(calculate('10 / 4')), '2.5');
      expect(formatNumber(calculate('pi')), '3.14159265359');
    });

    test('says what is wrong', () {
      expect(() => calculate('1 / 0'), throwsA(isA<CalcException>()));
      expect(() => calculate('2 +'), throwsA(isA<CalcException>()));
      expect(() => calculate('foo(2)'), throwsA(isA<CalcException>()));
    });
  });

  group('tool calls written as text', () {
    test('are taken out of the reply, even split across chunks', () {
      final p = ToolCallParser();
      final shown = [
        p.add('Let me check. <tool'),
        p.add('_call>{"name": "web_search", "argu'),
        p.add('ments": {"query": "weather"}}</tool_call> ok'),
        p.close(),
      ].join();
      expect(shown, 'Let me check.  ok');
      expect(p.calls.single.$1, 'web_search');
      expect(jsonDecode(p.calls.single.$2), {'query': 'weather'});
    });

    test('a "<" that is not a tag still shows', () {
      final p = ToolCallParser();
      expect([p.add('a < b and 2 <'), p.close()].join(), 'a < b and 2 <');
      expect(p.calls, isEmpty);
    });
  });

  group('agent loop', () {
    AgentTool echo() => AgentTool(
      name: 'echo',
      description: 'Says it back',
      parameters: const {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      },
      run: (a) async => 'echo: ${a['text']}',
    );

    test('runs native tool calls and sends the results back', () async {
      final seenTurns = <List<AiToolTurn>>[];
      Stream<AiChunk> turn({
        required List<AiMessage> messages,
        String? system,
        required List<AiToolSpec> tools,
        required List<AiToolTurn> turns,
      }) async* {
        seenTurns.add([...turns]);
        expect(tools.single.name, 'echo');
        if (turns.isEmpty) {
          yield const AiChunk(text: 'Checking. ');
          yield const AiChunk(
            tools: [AiToolDelta(0, id: 't1', name: 'echo')],
          );
          yield const AiChunk(tools: [AiToolDelta(0, arguments: '{"text":')]);
          yield const AiChunk(tools: [AiToolDelta(0, arguments: '"hi"}')]);
        } else {
          yield AiChunk(text: 'Done: ${turns.single.results.single}');
        }
      }

      final events = await runAgent(
        turn: turn,
        messages: const [AiMessage('user', 'say hi')],
        tools: [echo()],
      ).toList();
      final out = AgentOutput();
      events.forEach(out.add);
      expect(out.content, 'Checking. \n\nDone: echo: hi');
      expect(seenTurns.length, 2);
      final items = out.output(done: true);
      expect(items.map((i) => i['type']), [
        'message',
        'function_call',
        'function_call_output',
        'message',
      ]);
      expect(items[1]['status'], 'completed');
    });

    test(
      'teaches models without tool calling, and parses their calls',
      () async {
        final systems = <String?>[];
        final sent = <List<AiMessage>>[];
        Stream<AiChunk> turn({
          required List<AiMessage> messages,
          String? system,
          required List<AiToolSpec> tools,
          required List<AiToolTurn> turns,
        }) async* {
          systems.add(system);
          sent.add(messages);
          expect(tools, isEmpty);
          if (messages.length == 1) {
            yield const AiChunk(
              text:
                  '<tool_call>{"name":"echo","arguments":{"text":"yo"}}'
                  '</tool_call>',
            );
          } else {
            yield const AiChunk(text: 'It said yo.');
          }
        }

        final events = await runAgent(
          turn: turn,
          messages: const [AiMessage('user', 'hi')],
          system: 'Be nice.',
          tools: [echo()],
          nativeTools: false,
        ).toList();
        expect(systems.first, contains('Be nice.'));
        expect(systems.first, contains('<tool_call>'));
        expect(sent.last.last.text, contains('echo: yo'));
        expect(
          events.whereType<AgentText>().map((e) => e.text).join(),
          'It said yo.',
        );
      },
    );

    test('an unknown tool or an error goes back to the model', () async {
      var round = 0;
      Stream<AiChunk> turn({
        required List<AiMessage> messages,
        String? system,
        required List<AiToolSpec> tools,
        required List<AiToolTurn> turns,
      }) async* {
        round++;
        if (round == 1) {
          yield const AiChunk(
            tools: [AiToolDelta(0, id: 'x', name: 'nope')],
          );
        } else {
          expect(turns.single.results.single, contains('no tool'));
          yield const AiChunk(text: 'Sorry.');
        }
      }

      final events = await runAgent(
        turn: turn,
        messages: const [AiMessage('user', 'hi')],
        tools: [echo()],
      ).toList();
      expect(events.whereType<AgentToolDone>().single.failed, isTrue);
    });
  });

  group('provider requests with tools', () {
    const spec = AiToolSpec('echo', 'Says it back', {
      'type': 'object',
      'properties': {},
    });
    const turn = AiToolTurn('', [AiToolCall('c1', 'echo', '{"a":1}')], ['ok']);

    test('OpenAI style', () {
      final body = openAiBody(
        'gpt',
        const [AiMessage('user', 'hi')],
        tools: const [spec],
        turns: const [turn],
      );
      expect((body['tools'] as List).single['function']['name'], 'echo');
      final msgs = body['messages'] as List;
      expect(msgs[1]['tool_calls'][0]['id'], 'c1');
      expect(msgs[2], {'role': 'tool', 'tool_call_id': 'c1', 'content': 'ok'});
    });

    test('Claude', () {
      final body = anthropicBody(
        'claude',
        const [AiMessage('user', 'hi')],
        tools: const [spec],
        turns: const [turn],
      );
      expect((body['tools'] as List).single['input_schema'], isNotNull);
      final msgs = body['messages'] as List;
      expect(msgs[1]['content'][0], {
        'type': 'tool_use',
        'id': 'c1',
        'name': 'echo',
        'input': {'a': 1},
      });
      expect(msgs[2]['content'][0]['tool_use_id'], 'c1');
    });

    test('streamed tool calls are read', () {
      final o = openAiChunk({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'a',
                  'function': {'name': 'echo', 'arguments': '{'},
                },
              ],
            },
          },
        ],
      })!;
      expect(o.tools.single.name, 'echo');
      final start = anthropicChunk({
        'type': 'content_block_start',
        'index': 1,
        'content_block': {'type': 'tool_use', 'id': 'b', 'name': 'echo'},
      })!;
      expect(start.tools.single.index, 1);
      final more = anthropicChunk({
        'type': 'content_block_delta',
        'index': 1,
        'delta': {'type': 'input_json_delta', 'partial_json': '{"a"'},
      })!;
      expect(more.tools.single.arguments, '{"a"');
    });
  });

  group('web', () {
    test('reads DuckDuckGo results', () {
      const html = '''
<div class="result results_links results_links_deep web-result ">
<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=x">Example &amp; Co</a>
<a class="result__snippet" href="x">The <b>best</b> example.</a>
</div>''';
      final r = parseDuckDuckGo(html).single;
      expect(r.title, 'Example & Co');
      expect(r.url, 'https://example.com/a');
      expect(r.snippet, 'The best example.');
    });

    test('turns a page into readable text', () {
      final p = pageText('''<html><head><title>Hi</title>
<style>.x{}</style><script>var a=1;</script></head><body>
<nav>Menu</nav><h1>Big</h1><p>Hello <a href="https://a.com">there</a></p>
<ul><li>One</li><li>Two</li></ul></body></html>''');
      expect(p.title, 'Hi');
      expect(p.text, contains('# Big'));
      expect(p.text, contains('Hello [there](https://a.com)'));
      expect(p.text, contains('- One'));
      expect(p.text, isNot(contains('Menu')));
      expect(p.text, isNot(contains('var a')));
    });
  });

  group('skills', () {
    test('read from SKILL.md', () {
      final s = parseSkillMd(
        '---\nname: Pirate talk\ndescription: "Talk like a pirate"\n---\n\n'
        'Say arr.',
      )!;
      expect(s.id, 'pirate-talk');
      expect(s.description, 'Talk like a pirate');
      expect(s.content, 'Say arr.');
    });

    test('read from a .skill archive', () {
      final a = Archive()
        ..addFile(
          ArchiveFile.bytes(
            'pirate/SKILL.md',
            utf8.encode('---\ndescription: d\n---\nSay arr.'),
          ),
        );
      final s = skillsFromFile('p.skill', ZipEncoder().encode(a)).single;
      expect(s.name, 'pirate');
    });

    test('built-in ones are complete', () {
      for (final s in builtInSkills) {
        expect(s.description, isNotEmpty);
        expect(s.content, isNotEmpty);
        expect(s.builtIn, isTrue);
      }
    });
  });

  group('MCP', () {
    test('lists and calls tools over Streamable HTTP', () async {
      final methods = <String>[];
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map;
        methods.add('${body['method']}');
        if (body['id'] == null) return http.Response('', 202);
        if (body['method'] != 'initialize') {
          expect(req.headers['mcp-session-id'], 's1');
          expect(req.headers['authorization'], 'Bearer k');
        }
        final result = switch (body['method']) {
          'initialize' => {
            'protocolVersion': mcpProtocolVersion,
            'serverInfo': {'name': 'Test'},
          },
          'tools/list' => {
            'tools': [
              {
                'name': 'add',
                'description': 'Adds',
                'inputSchema': {'type': 'object'},
              },
            ],
          },
          _ => {
            'content': [
              {'type': 'text', 'text': '3'},
            ],
          },
        };
        final json = jsonEncode({
          'jsonrpc': '2.0',
          'id': body['id'],
          'result': result,
        });
        // tools/call answers as an event stream, the rest as JSON.
        return body['method'] == 'tools/call'
            ? http.Response(
                'event: message\ndata: $json\n\n',
                200,
                headers: {'content-type': 'text/event-stream'},
              )
            : http.Response(
                json,
                200,
                headers: {
                  'content-type': 'application/json',
                  'mcp-session-id': 's1',
                },
              );
      });
      final mcp = McpClient(
        'https://x.test/mcp',
        token: 'k',
        httpClient: client,
      );
      final tools = await mcp.listTools();
      expect(tools.single.name, 'add');
      final r = await mcp.callTool('add', {'a': 1, 'b': 2});
      expect(r.text, '3');
      expect(methods, [
        'initialize',
        'notifications/initialized',
        'tools/list',
        'tools/call',
      ]);
    });

    test('a 401 asks for a sign-in', () async {
      final client = MockClient(
        (_) async => http.Response(
          '',
          401,
          headers: {
            'www-authenticate': 'Bearer resource_metadata="https://x.test/.well-known/oauth-protected-resource"',
          },
        ),
      );
      final mcp = McpClient('https://x.test/mcp', httpClient: client);
      await expectLater(
        mcp.listTools(),
        throwsA(
          isA<McpException>()
              .having((e) => e.needsSignIn, 'needsSignIn', isTrue)
              .having(
                (e) => e.authenticate,
                'authenticate',
                contains('x.test'),
              ),
        ),
      );
    });

    test('finds where to sign in', () async {
      final client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/.well-known/oauth-protected-resource') {
          return http.Response(
            jsonEncode({
              'resource': 'https://x.test/mcp',
              'authorization_servers': ['https://auth.test'],
              'scopes_supported': ['read'],
            }),
            200,
          );
        }
        if (req.url.host == 'auth.test' &&
            path == '/.well-known/oauth-authorization-server') {
          return http.Response(
            jsonEncode({
              'authorization_endpoint': 'https://auth.test/a',
              'token_endpoint': 'https://auth.test/t',
              'registration_endpoint': 'https://auth.test/r',
            }),
            200,
          );
        }
        return http.Response('', 404);
      });
      final a = await discoverMcpAuth(
        'https://x.test/mcp',
        authenticate: 'Bearer resource_metadata="https://x.test/.well-known/oauth-protected-resource"',
        httpClient: client,
      );
      expect('${a.authorize}', 'https://auth.test/a');
      expect('${a.token}', 'https://auth.test/t');
      expect('${a.register}', 'https://auth.test/r');
      expect(a.scopes, ['read']);
      expect(a.resource, 'https://x.test/mcp');
    });

    test('tool names fit every provider', () {
      expect(toolName('github__create issue!'), 'github__create_issue_');
      expect(toolName('a' * 80).length, 64);
    });
  });
}
