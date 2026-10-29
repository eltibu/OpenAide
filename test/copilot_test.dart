import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_assistant/core/ai/ai_providers.dart';
import 'package:nexus_assistant/core/ai/copilot.dart';

void main() {
  test('waits through pending and slow_down for the GitHub token', () async {
    final answers = [
      {'error': 'authorization_pending'},
      {'error': 'slow_down', 'interval': 10},
      {'access_token': 'gho_abc'},
    ];
    final waits = <int>[];
    final client = MockClient((req) async {
      expect(req.url.toString(), 'https://github.com/login/oauth/access_token');
      expect(
        req.bodyFields['grant_type'],
        'urn:ietf:params:oauth:grant-type:device_code',
      );
      return http.Response(jsonEncode(answers.removeAt(0)), 200);
    });
    final token = await waitForGitHubSignIn(
      const DeviceCode(
        deviceCode: 'dev',
        userCode: 'ABCD-1234',
        verificationUri: 'https://github.com/login/device',
        interval: 5,
        expiresIn: 900,
      ),
      httpClient: client,
      delay: (s) {
        waits.add(s);
        return Duration.zero;
      },
    );
    expect(token, 'gho_abc');
    expect(waits, [5, 5, 10]);
  });

  test('a refused sign-in says so', () async {
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'error': 'access_denied'}), 200),
    );
    expect(
      waitForGitHubSignIn(
        const DeviceCode(
          deviceCode: 'd',
          userCode: 'u',
          verificationUri: 'v',
          interval: 1,
          expiresIn: 60,
        ),
        httpClient: client,
        delay: (_) => Duration.zero,
      ),
      throwsA(isA<AiException>()),
    );
  });

  test('lists Copilot chat models with the exchanged token', () async {
    final client = MockClient((req) async {
      if (req.url.host == 'api.github.com') {
        expect(req.headers['Authorization'], 'token gho_1');
        return http.Response(
          jsonEncode({
            'token': 'tid_xyz',
            'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 1500,
            'endpoints': {'api': 'https://api.individual.githubcopilot.com'},
          }),
          200,
        );
      }
      expect(
        req.url.toString(),
        'https://api.individual.githubcopilot.com/models',
      );
      expect(req.headers['Authorization'], 'Bearer tid_xyz');
      return http.Response(
        jsonEncode({
          'data': [
            {
              'id': 'claude-sonnet-4.5',
              'name': 'Claude Sonnet 4.5',
              'model_picker_enabled': true,
              'capabilities': {
                'type': 'chat',
                'supports': {'vision': true},
              },
            },
            {
              'id': 'text-embedding-3-small',
              'capabilities': {'type': 'embeddings'},
            },
          ],
        }),
        200,
      );
    });
    final models = await listProviderModels(
      AiProvider.copilot,
      'gho_1',
      httpClient: client,
    );
    expect(models.single.id, 'direct:copilot:claude-sonnet-4.5');
    expect(models.single.capabilities['vision'], isTrue);
  });

  test("sign-in uses OpenAide's own GitHub app by default", () {
    // Tests run without --dart-define=NEXUS_GITHUB_CLIENT_ID.
    expect(copilotSignInAvailable, isTrue);
  });

  test('only sends the token to https Copilot hosts', () {
    expect(
      copilotApiBase('https://api.individual.githubcopilot.com/'),
      'https://api.individual.githubcopilot.com',
    );
    expect(
      copilotApiBase('https://evil.example.com'),
      'https://api.githubcopilot.com',
    );
    expect(
      copilotApiBase('http://api.githubcopilot.com'),
      'https://api.githubcopilot.com',
    );
    expect(
      copilotApiBase('https://githubcopilot.com.evil.io'),
      'https://api.githubcopilot.com',
    );
    expect(copilotApiBase(null), 'https://api.githubcopilot.com');
  });
}
