import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/settings/tool_servers.dart';

void main() {
  final mine = [
    {'url': 'http://pc:8000', 'key': 'a'},
    {'url': 'http://nas:8000', 'key': 'b'},
  ];

  test('only the chat\'s own terminal goes with the message', () {
    final sent = chatToolServers(
      const {},
      const [],
      mine,
      terminalId: 'http://nas:8000',
    );
    expect(sent, [
      {'url': 'http://nas:8000', 'key': 'b', 'is_terminal': true},
    ]);
  });

  test('none when the chat uses the admin\'s terminal or none', () {
    expect(chatToolServers(const {}, const [], mine), isEmpty);
    expect(
      chatToolServers(const {}, const [], mine, terminalId: 'system-1'),
      isEmpty,
    );
  });

  test('none when the model may not use a terminal', () {
    expect(
      chatToolServers(
        const {},
        const [],
        mine,
        terminal: false,
        terminalId: 'http://pc:8000',
      ),
      isEmpty,
    );
  });

  test('picked tool servers still go along', () {
    final sent = chatToolServers(
      {'${directServerPrefix}1'},
      [
        {'url': 'http://t0'},
        {'url': 'http://t1'},
      ],
      mine,
    );
    expect(sent, [
      {'url': 'http://t1'},
    ]);
  });
}
