import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/request_options.dart';
import 'package:nexus_assistant/features/chat/tool_auth.dart';

void main() {
  test('tool sign-in goes where the web sends it', () {
    expect(
      toolSignInPath('server:mcp:github'),
      '/oauth/clients/mcp:github/authorize',
    );
    expect(
      toolSignInPath('server:oauth:abc'),
      '/oauth/clients/oauth:abc/authorize',
    );
    expect(toolSignInPath('plain'), '/oauth/clients/mcp:plain/authorize');
    expect(toolSessionProvider('server:mcp:github'), 'mcp:github');
  });

  test('tools say whether they need a sign-in', () {
    expect(
      Pickable.fromJson({'id': 'server:mcp:x', 'authenticated': false})
          .authenticated,
      isFalse,
    );
    expect(Pickable.fromJson({'id': 'mine'}).authenticated, isNull);
  });
}
