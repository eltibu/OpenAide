// Open WebUI 0.13.3: agents in automations, agents kept out of pickers that
// can't use them, grouped tool call labels, side chats when temporary chats
// are off.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/model_info.dart';
import 'package:nexus_assistant/features/automations/automations_api.dart';
import 'package:nexus_assistant/features/chat/model_pins.dart';
import 'package:nexus_assistant/features/chat/reply_parts.dart';
import 'package:nexus_assistant/features/chat/side_chat.dart';

void main() {
  test('an automation knows its terminal, folder and agent', () {
    final a = Automation.fromJson({
      'id': 'a1',
      'name': 'Nightly review',
      'is_active': true,
      'data': {
        'prompt': 'review the repo',
        'model_id': 'agent:local:claude:sonnet',
        'rrule': 'RRULE:FREQ=DAILY;BYHOUR=3;BYMINUTE=0',
        'target': {'type': 'chat'},
        'terminal': {'server_id': 'local', 'cwd': '/home/me/project'},
      },
    });
    expect(a.terminalId, 'local');
    expect(a.cwd, '/home/me/project');
    expect(a.isAgent, isTrue);
    expect(a.channelId, isNull);

    final plain = Automation.fromJson({
      'id': 'a2',
      'name': 'News',
      'data': {'model_id': 'fake'},
    });
    expect(plain.terminalId, '');
    expect(plain.cwd, '');
    expect(plain.isAgent, isFalse);
  });

  test('an agent id reads as provider/model', () {
    expect(agentLabel('agent:local:claude:sonnet'), 'claude/sonnet');
    expect(agentLabel('agent:my%20pc:codex:gpt-5%3Amini'), 'codex/gpt-5:mini');
    expect(agentLabel('fake'), 'fake');
    expect(agentLabel('agent:broken'), 'agent:broken');
  });

  test('a terminal agent is never offered for editing', () {
    final agent = ModelInfo.fromJson({
      'id': 'agent:local:claude:sonnet',
      'name': 'claude/sonnet',
      'owned_by': 'terminal',
      'agent': {'terminal_id': 'local', 'provider': 'claude'},
    });
    expect(agent.isAgent, isTrue);
    expect(canEditModel(agent, {'id': 'u1', 'role': 'admin'}), isFalse);
    final server = ModelInfo.fromJson({'id': 'fake', 'owned_by': 'openai'});
    expect(canEditModel(server, {'id': 'u1', 'role': 'admin'}), isTrue);
  });

  group('grouped tool call labels', () {
    test('labels stay when one call has none', () {
      expect(
        stepsSummary(const [
          ToolPart(name: 'search_web', completed: 'Searched for news'),
          ToolPart(name: 'fetch_url'),
        ]),
        'Searched for news, fetch url',
      );
    });

    test('no labels at all keeps the usual summary', () {
      expect(
        stepsSummary(const [
          ToolPart(name: 'search_web'),
          ToolPart(name: 'fetch_url'),
        ]),
        'Used search web and fetch url',
      );
    });

    test('a failed or running call keeps the usual summary', () {
      expect(
        stepsSummary(const [
          ToolPart(name: 'search_web', completed: 'Searched'),
          ToolPart(name: 'fetch_url', failed: true),
        ]),
        'Used search web and fetch url',
      );
      expect(
        stepsSummary(const [
          ToolPart(name: 'search_web', completed: 'Searched'),
          ToolPart(name: 'fetch_url', done: false),
        ]),
        'Used search web and fetch url',
      );
    });

    test('thinking in the group keeps the usual summary', () {
      expect(
        stepsSummary(const [
          ThinkingPart('hmm', seconds: 3),
          ToolPart(name: 'search_web', completed: 'Searched'),
        ]),
        'Thought for 3s, used search web',
      );
    });
  });

  test('side chats save when temporary chats are off, even if enforced', () {
    Map me(Map<String, dynamic> chat) => {
      'role': 'user',
      'permissions': {'chat': chat},
    };
    expect(sideChatCanSave(me({'temporary_enforced': true})), isFalse);
    expect(
      sideChatCanSave(me({'temporary': false, 'temporary_enforced': true})),
      isTrue,
    );
    expect(sideChatCanSave(me({})), isTrue);
  });
}
