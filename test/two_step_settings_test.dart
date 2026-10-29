import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/settings/two_step_settings.dart';

/// A stand-in server where 123456 is the current code, 654321 the new
/// authenticator's, and 000000 a code from too long ago.
OpenWebUiClient fakeClient(List<String> calls) => OpenWebUiClient(
  baseUrl: 'http://fake',
  token: 't',
  httpClient: MockClient((req) async {
    calls.add(req.url.path);
    final body = req.body.isEmpty ? const {} : jsonDecode(req.body) as Map;
    http.Response json(Object o, [int status = 200]) =>
        http.Response(jsonEncode(o), status);
    switch (req.url.path) {
      case '/api/v1/auths/mfa/status':
        return json({
          'enabled': true,
          'required': true,
          'recovery_codes_remaining': 8,
        });
      case '/api/v1/auths/mfa/recovery/codes' || '/api/v1/auths/mfa/replace':
        if (body['code'] == '000000') {
          return json({'detail': 'reauthentication_required'}, 403);
        }
        if (body['code'] != '123456') return json({'detail': 'Bad code'}, 400);
        return req.url.path.endsWith('replace')
            ? json({
                'next_step': 'enroll',
                'challenge_token': 'r' * 24,
                'expires_in': 300,
              })
            : json({
                'recovery_codes': ['new1-new1', 'new2-new2'],
              });
      case '/api/v1/auths/mfa/enroll/start':
        return json({'manual_key': 'KEYKEYKEY', 'qr_code': ''});
      case '/api/v1/auths/mfa/enroll/confirm':
        if (body['challenge_token'] != 'r' * 24 || body['code'] != '654321') {
          return json({'detail': 'Bad code'}, 400);
        }
        return json({
          'recovery_codes': ['rep1-rep1'],
        });
    }
    return json({'detail': 'Not found'}, 404);
  }),
);

Future<void> pumpManage(WidgetTester tester, List<String> calls) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [clientProvider.overrideWithValue(fakeClient(calls))],
      child: MaterialApp(
        theme: nexusTheme(Brightness.light),
        home: const TwoStepManageScreen(),
      ),
    ),
  );
}

void main() {
  test('summary and fresh sign-in check', () {
    expect(
      twoStepSummary({'enabled': true, 'recovery_codes_remaining': 3}),
      'Authenticator configured. 3 recovery codes remaining.',
    );
    expect(
      twoStepSummary({'enabled': false}),
      'Managed by your administrator.',
    );
    expect(
      needsFreshSignIn(ApiException(403, 'reauthentication_required')),
      isTrue,
    );
    expect(needsFreshSignIn(ApiException(400, 'Bad code')), isFalse);
  });

  testWidgets('settings tile shows the status', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(fakeClient([]))],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const Scaffold(body: TwoStepSettings()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Multi-factor authentication'), findsOneWidget);
    expect(find.textContaining('8 recovery codes'), findsOneWidget);
  });

  testWidgets('new recovery codes', (tester) async {
    final calls = <String>[];
    await pumpManage(tester, calls);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('Generate recovery codes'));
    await tester.pumpAndSettle();
    expect(find.text('new1-new1\nnew2-new2'), findsOneWidget);
    expect(calls, contains('/api/v1/auths/mfa/recovery/codes'));
  });

  testWidgets('replace authenticator', (tester) async {
    final calls = <String>[];
    await pumpManage(tester, calls);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('Replace authenticator'));
    await tester.pumpAndSettle();
    expect(find.text('KEYKEYKEY'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '654321');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('rep1-rep1'), findsOneWidget);
  });

  testWidgets('an old sign-in asks to sign in again', (tester) async {
    await pumpManage(tester, []);
    await tester.enterText(find.byType(TextField), '000000');
    await tester.tap(find.text('Generate recovery codes'));
    await tester.pumpAndSettle();
    expect(
      find.text('Sign in again before changing your authenticator settings.'),
      findsOneWidget,
    );
    expect(find.text('Sign in again'), findsOneWidget);
  });
}
