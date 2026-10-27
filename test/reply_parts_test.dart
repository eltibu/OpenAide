import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/chat/reply_parts.dart';

void main() {
  ChatMessage reply({String content = '', List? output, List? statusHistory}) =>
      ChatMessage.fromJson({
        'id': 'r',
        'role': 'assistant',
        'content': content,
        'output': ?output,
        'statusHistory': ?statusHistory,
      });

  test('output items come out in order, steps grouped', () {
    final m = reply(
      output: [
        {
          'type': 'reasoning',
          'status': 'completed',
          'duration': 8,
          'content': [
            {'type': 'output_text', 'text': 'Look at the inbox.'},
          ],
        },
        {
          'type': 'function_call',
          'call_id': 'c1',
          'name': 'search_gmail',
          'arguments': '{"q":"is:unread"}',
          'status': 'completed',
        },
        {
          'type': 'function_call_output',
          'call_id': 'c1',
          'output': [
            {'type': 'input_text', 'text': '3 emails'},
          ],
        },
        {
          'type': 'message',
          'content': [
            {'type': 'output_text', 'text': 'You have 3 unread.'},
          ],
        },
        {
          'type': 'function_call',
          'call_id': 'c2',
          'name': 'send_email',
          'arguments': '{}',
          'status': 'failed',
        },
        {
          'type': 'message',
          'content': [
            {'type': 'output_text', 'text': 'Sending failed.'},
          ],
        },
      ],
    );
    final groups = groupParts(replyParts(m));
    expect(groups.length, 4);
    final first = groups[0] as List<StepPart>;
    expect((first[0] as ThinkingPart).text, 'Look at the inbox.');
    expect((first[0] as ThinkingPart).seconds, 8);
    expect((first[1] as ToolPart).result, '3 emails');
    expect(stepsSummary(first), 'Thought for 8s, used search gmail');
    expect((groups[1] as TextPart).text, 'You have 3 unread.');
    expect(((groups[2] as List<StepPart>).single as ToolPart).failed, isTrue);
    expect((groups[3] as TextPart).text, 'Sending failed.');
  });

  test('task steps come first; the last one runs while live', () {
    final m = reply(
      content: 'Done.',
      statusHistory: [
        {'description': 'Searching the web', 'done': false},
        {'description': 'hidden', 'hidden': true},
        {'description': 'Reading 3 pages', 'done': false},
      ],
    );
    final live = replyParts(m, live: true);
    expect(live.length, 3);
    expect((live[0] as StatusPart).done, isTrue);
    expect((live[1] as StatusPart).done, isFalse);
    expect(currentStep(live.whereType<StepPart>().toList()), 'Reading 3 pages');
    expect(replyParts(m).whereType<StepPart>().every((s) => s.done), isTrue);
    expect((live.last as TextPart).text, 'Done.');
  });

  test('older servers: details blocks in the text', () {
    final m = reply(
      content:
          '<details type="reasoning" done="true" duration="4">\n'
          '<summary>Thought for 4 seconds</summary>\n'
          '> First line\n> second line\n</details>\n'
          'Here it is.\n\n'
          '<details type="tool_calls" done="true" id="x" name="get_time" '
          'arguments="&quot;{}&quot;" result="&quot;12:00&quot;">\n'
          '<summary>Tool Executed</summary>\n</details>\n'
          'It is noon.',
    );
    final parts = replyParts(m);
    expect(parts.length, 4);
    expect((parts[0] as ThinkingPart).text, 'First line\nsecond line');
    expect((parts[0] as ThinkingPart).seconds, 4);
    expect((parts[1] as TextPart).text, 'Here it is.');
    expect((parts[2] as ToolPart).name, 'get_time');
    expect((parts[2] as ToolPart).result, '12:00');
    expect((parts[3] as TextPart).text, 'It is noon.');
  });

  test('live events build the output as the web does', () {
    var out = <Map<String, dynamic>>[];
    void ev(Map e) => out = applyOutputEvent(out, e);
    ev({
      'type': 'response.output_item.added',
      'output_index': 0,
      'item': {'type': 'reasoning', 'id': 'r1', 'status': 'in_progress'},
    });
    ev({
      'type': 'response.reasoning_text.delta',
      'output_index': 0,
      'content_index': 0,
      'delta': 'Hmm, ',
    });
    ev({
      'type': 'response.reasoning_text.delta',
      'output_index': 0,
      'content_index': 0,
      'delta': 'let me check.',
    });
    var parts = outputParts(out, live: true);
    expect((parts.single as ThinkingPart).text, 'Hmm, let me check.');
    expect(parts.single is StepPart && !(parts.single as StepPart).done, true);
    expect(stepsSummary(parts.whereType<StepPart>().toList()), 'Thinking');

    ev({
      'type': 'response.output_item.done',
      'output_index': 0,
      'item': {
        'type': 'reasoning',
        'id': 'r1',
        'status': 'completed',
        'duration': 2,
        'content': [
          {'type': 'output_text', 'text': 'Hmm, let me check.'},
        ],
      },
    });
    ev({
      'type': 'response.output_item.added',
      'output_index': 1,
      'item': {
        'type': 'function_call',
        'id': 'f1',
        'call_id': 'c1',
        'name': 'get_time',
        'arguments': '',
        'status': 'in_progress',
      },
    });
    ev({
      'type': 'response.function_call_arguments.delta',
      'output_index': 1,
      'delta': '{"tz":',
    });
    ev({
      'type': 'response.function_call_arguments.delta',
      'output_index': 1,
      'delta': '"UTC"}',
    });
    parts = outputParts(out, live: true);
    final tool = parts[1] as ToolPart;
    expect(tool.arguments, '{"tz":"UTC"}');
    expect(tool.done, isFalse);
    expect(
      currentStep(parts.whereType<StepPart>().toList()),
      'Using get time…',
    );

    ev({
      'type': 'response.output_text.delta',
      'output_index': 2,
      'content_index': 0,
      'delta': 'Noon.',
    });
    parts = outputParts(out, live: true);
    expect((parts.last as TextPart).text, 'Noon.');
  });

  test('labels and JSON', () {
    expect(toolLabel('search_gmail'), 'search gmail');
    expect(toolLabel('readEmail'), 'read email');
    expect(prettyJson('{"a":1}'), '{\n  "a": 1\n}');
    expect(prettyJson('plain'), 'plain');
    expect(
      stepsSummary(const [
        ToolPart(name: 'a'),
        ToolPart(name: 'b'),
        ToolPart(name: 'c'),
      ]),
      'Used 3 tools',
    );
    expect(
      stepsSummary(const [ToolPart(name: 'a'), ToolPart(name: 'a')]),
      'Used a 2 times',
    );
  });
}
