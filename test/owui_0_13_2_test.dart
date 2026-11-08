// Open WebUI 0.13.1 and 0.13.2: hidden context tool calls, tool call
// labels, saved side chats, coding agents as models, Auto tool permissions.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/core/models/model_info.dart';
import 'package:nexus_assistant/features/chat/reply_parts.dart';
import 'package:nexus_assistant/features/chat/request_options.dart';
import 'package:nexus_assistant/features/chat/side_chat.dart';

void main() {
  final output = [
    // What 0.13.1 adds after your message: memories as a hidden tool result.
    {
      'type': 'function_call',
      'call_id': 'fc1',
      'name': 'recall_memories',
      'hidden': true,
      'arguments': '{}',
      'status': 'completed',
    },
    {
      'type': 'function_call_output',
      'call_id': 'fc1',
      'output': [
        {'type': 'input_text', 'text': 'Likes tea'},
      ],
    },
    {
      'type': 'function_call',
      'call_id': 'fc2',
      'name': 'search_web',
      'arguments': '{"q":"weather"}',
      'display_labels': {
        'running': 'Looking up the weather',
        'completed': 'Looked up the weather',
      },
      'status': 'completed',
    },
    {
      'type': 'function_call_output',
      'call_id': 'fc2',
      'output': [
        {'type': 'input_text', 'text': 'Sunny'},
      ],
    },
    {
      'type': 'message',
      'content': [
        {'type': 'output_text', 'text': 'It is sunny.'},
      ],
    },
  ];

  test('hidden context tool calls are not shown', () {
    final parts = outputParts(output);
    final tools = parts.whereType<ToolPart>().toList();
    expect(tools, hasLength(1));
    expect(tools.single.name, 'search_web');
    expect(tools.single.result, 'Sunny');
    final m = ChatMessage(
      id: 'a',
      role: 'assistant',
      content: 'It is sunny.',
      extra: {'output': output},
    );
    expect(m.toolCalls.map((t) => t.name), ['search_web']);
  });

  test('tool call labels are read', () {
    final tool = outputParts(output).whereType<ToolPart>().single;
    expect(tool.running, 'Looking up the weather');
    expect(tool.completed, 'Looked up the weather');
    expect(
      currentStep([
        ToolPart(name: 'x', running: 'Reading the file', done: false),
      ]),
      'Reading the file',
    );
    expect(toolCallLabels({'display_labels': 'bad'}).running, isNull);
  });

  test('side chats: permission and saving follow 0.13.1', () {
    // No longer needs the Temporary Chat permission.
    expect(
      sideChatAllowed({
        'role': 'user',
        'permissions': {
          'chat': {'temporary': false, 'side_chat': true},
        },
      }),
      isTrue,
    );
    expect(
      sideChatAllowed({
        'role': 'user',
        'permissions': {'chat': <String, dynamic>{}},
      }),
      isFalse,
    );
    expect(sideChatAllowed({'role': 'admin'}), isTrue);
    expect(
      sideChatCanSave({
        'role': 'user',
        'permissions': {
          'chat': {'temporary_enforced': true},
        },
      }),
      isFalse,
    );
    expect(serverSavesSideChats('0.13.0'), isFalse);
    expect(serverSavesSideChats('0.13.1'), isTrue);
    expect(serverSavesSideChats('0.13.2'), isTrue);
    expect(serverSavesSideChats('0.14.0'), isTrue);
    expect(serverSavesSideChats('0.12.5'), isFalse);
    expect(serverSavesSideChats('1.0.0'), isTrue);

    final h = sideChatHistory([
      {'id': 'u1', 'role': 'user', 'content': 'hi'},
      {'id': 'a1', 'role': 'assistant', 'content': 'hello'},
    ]);
    expect(h['currentId'], 'a1');
    final msgs = h['messages'] as Map;
    expect((msgs['u1'] as Map)['parentId'], isNull);
    expect((msgs['u1'] as Map)['childrenIds'], ['a1']);
    expect((msgs['a1'] as Map)['parentId'], 'u1');
    expect((msgs['a1'] as Map)['childrenIds'], isEmpty);
  });

  test('coding agents are models with their terminal', () {
    final agent = ModelInfo.fromJson({
      'id': 'agent:local:claude:sonnet',
      'name': 'claude/sonnet',
      'owned_by': 'agent',
      'agent': {
        'terminal_id': 'local',
        'provider': 'claude',
        'model': 'sonnet',
      },
    });
    expect(agent.isAgent, isTrue);
    expect(agent.terminalId, 'local');
    final plain = ModelInfo.fromJson({'id': 'gpt', 'name': 'GPT'});
    expect(plain.isAgent, isFalse);
    expect(
      requestOptions(agent, const {}, const {})['terminal_id'],
      'local',
    );
  });

  test('tool permissions: Auto as the web resolves it', () {
    expect(toolApprovalMode(const {}, null), 'full');
    expect(toolApprovalMode(const {}, null, autoEnabled: true), 'auto');
    expect(toolApprovalMode({'tool_approval_mode': 'auto'}, null), 'ask');
    expect(
      toolApprovalMode({'tool_approval_mode': 'ask'}, null, autoEnabled: true),
      'ask',
    );
    final opts = requestOptions(null, const {}, {
      'features': {
        'enable_tool_permissions': true,
        'enable_tool_permissions_auto': true,
      },
    });
    expect((opts['params'] as Map)['tool_approval_mode'], 'auto');
    final off = requestOptions(null, const {}, const {'features': {}});
    expect(off['params'], isNull);
  });
}
