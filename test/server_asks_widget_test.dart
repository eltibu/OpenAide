import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/chat_socket.dart';
import 'package:nexus_assistant/features/chat/server_asks.dart';

void main() {
  Future<Object?> ask(
    WidgetTester tester,
    Map<String, dynamic> data,
    Future<void> Function() act,
  ) async {
    Object? answer = 'unset';
    final call = SocketCall({'chat_id': 'c', 'data': data}, (v) => answer = v);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final v = await showDialog<Object?>(
                context: context,
                builder: (_) => AskDialog(call: call),
              );
              call.reply(v ?? cancelAnswer(call));
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await act();
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('a function asks for a value', (tester) async {
    final v = await ask(
      tester,
      {
        'type': 'input',
        'data': {'title': 'Your name', 'message': 'Who are you?'},
      },
      () async {
        expect(find.text('Who are you?'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'Joel');
        await tester.tap(find.text('Confirm'));
      },
    );
    expect(v, 'Joel');
  });

  testWidgets('a confirmation closed is a no', (tester) async {
    final v = await ask(tester, {
      'type': 'confirmation',
      'data': {'title': 'Sure?', 'message': 'Delete it'},
    }, () => tester.tap(find.byTooltip('Close')));
    expect(v, false);
  });

  testWidgets('a tool to allow', (tester) async {
    final v = await ask(
      tester,
      {
        'type': 'confirmation',
        'data': {
          'tool_call': {
            'name': 'search',
            'arguments': {'q': 'x'},
          },
        },
      },
      () async {
        expect(find.text('Tool Permissions'), findsOneWidget);
        await tester.tap(find.text('Allow'));
      },
    );
    expect(v, true);
  });

  testWidgets('an MCP form needs its required fields', (tester) async {
    final v = await ask(
      tester,
      {
        'type': 'request:elicitation',
        'data': {
          'server_name': 'Files',
          'message': 'Which folder?',
          'requestedSchema': {
            'properties': {
              'folder': {'type': 'string', 'title': 'Folder'},
            },
            'required': ['folder'],
          },
        },
      },
      () async {
        await tester.tap(find.text('Submit'));
        await tester.pump();
        expect(find.text('Fill in each required field.'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), 'Docs');
        await tester.tap(find.text('Submit'));
      },
    );
    expect(v, {
      'action': 'accept',
      'content': {'folder': 'Docs'},
    });
  });
}
