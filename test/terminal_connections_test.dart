import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/settings/terminal_connections.dart';
import 'package:nexus_assistant/features/terminal/terminal_api.dart';

void main() {
  test('your own terminals: switched-on ones, named or by address', () {
    final ui = {
      'terminalServers': [
        {'url': 'http://pc:8000', 'key': ' k ', 'name': '', 'enabled': true},
        {'url': 'http://nas:8000', 'name': 'NAS', 'enabled': false},
        {'url': '', 'name': 'blank'},
        'junk',
      ],
    };
    expect(userTerminalConfigs(ui), hasLength(2));
    final on = userTerminals(ui);
    expect(on, hasLength(1));
    expect(on.single.name, 'http://pc:8000');
    expect(on.single.id, 'http://pc:8000');
    expect(on.single.key, 'k');
    expect(on.single.direct, isTrue);
    expect(userTerminals(null), isEmpty);
  });

  test('only one is switched on at a time, as on the web', () {
    final list = [
      {'url': 'a', 'enabled': true},
      {'url': 'b', 'enabled': false},
    ];
    final next = onlyEnabled(list, 1);
    expect(next.map((s) => s['enabled']), [false, true]);
    expect(next[1]['url'], 'b');
  });

  test('your own terminal is reached at its address with its key', () {
    final api = TerminalApi(
      OpenWebUiClient(baseUrl: 'https://chat.example', token: 'mine'),
      const TerminalServer(
        id: 'http://pc:8000',
        name: 'PC',
        url: 'http://pc:8000',
        key: 'secret',
      ),
    );
    expect(api.client.baseUrl, 'http://pc:8000');
    expect(api.client.token, 'secret');
    expect(api.proxyPath(3000), '/proxy/3000/');
    final admin = TerminalApi(
      OpenWebUiClient(baseUrl: 'https://chat.example', token: 'mine'),
      const TerminalServer(id: 't1', name: 'T1'),
    );
    expect(admin.client.token, 'mine');
    expect(admin.proxyPath(3000), '/api/v1/terminals/t1/proxy/3000/');
  });

  test('a terminal that is not there says so', () async {
    expect(
      await checkTerminal('http://127.0.0.1:1', 'k'),
      startsWith("Couldn't reach it"),
    );
  });
}
