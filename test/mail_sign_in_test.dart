import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_assistant/core/ai/copilot.dart' show DeviceCode;
import 'package:nexus_assistant/features/accounts/mail_accounts.dart';
import 'package:nexus_assistant/features/accounts/mail_sign_in.dart';

String idToken(Map claims) =>
    'x.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.y';

const code = DeviceCode(
  deviceCode: 'dev',
  userCode: 'ABCD1234',
  verificationUri: 'https://microsoft.com/link',
  interval: 5,
  expiresIn: 900,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Microsoft: waits for the code, then knows the address', () async {
    final answers = [
      {'error': 'authorization_pending'},
      {'error': 'slow_down'},
      {
        'access_token': 'at',
        'refresh_token': 'rt',
        'expires_in': 3600,
        'id_token': idToken({
          'preferred_username': 'joel@outlook.com',
          'name': 'Joel',
        }),
      },
    ];
    final waits = <int>[];
    final client = MockClient((req) async {
      expect(
        req.url.toString(),
        'https://login.microsoftonline.com/common/oauth2/v2.0/token',
      );
      return http.Response(jsonEncode(answers.removeAt(0)), 400);
    });
    final grant = await waitForMicrosoftSignIn(
      code,
      httpClient: client,
      delay: (s) {
        waits.add(s);
        return Duration.zero;
      },
    );
    expect(grant.email, 'joel@outlook.com');
    expect(grant.name, 'Joel');
    expect(grant.refreshToken, 'rt');
    expect(waits, [5, 5, 10]);
  });

  test('Microsoft: a declined sign-in says so', () async {
    final client = MockClient(
      (_) async =>
          http.Response(jsonEncode({'error': 'authorization_declined'}), 400),
    );
    expect(
      waitForMicrosoftSignIn(
        code,
        httpClient: client,
        delay: (_) => Duration.zero,
      ),
      throwsA(
        isA<MailSignInError>().having(
          (e) => e.message,
          'message',
          contains('cancelled'),
        ),
      ),
    );
  });

  test('Google: trades the code with PKCE for a refresh token', () async {
    final client = MockClient((req) async {
      expect(req.url.toString(), 'https://oauth2.googleapis.com/token');
      expect(req.bodyFields['code_verifier'], 'ver');
      expect(req.bodyFields['redirect_uri'], 'http://127.0.0.1:5555');
      expect(req.bodyFields['grant_type'], 'authorization_code');
      return http.Response(
        jsonEncode({
          'access_token': 'at',
          'refresh_token': 'rt',
          'expires_in': 3599,
          'id_token': idToken({'email': 'joel@gmail.com'}),
        }),
        200,
      );
    });
    final grant = await exchangeGoogleCode(
      'code',
      'ver',
      'http://127.0.0.1:5555',
      httpClient: client,
    );
    expect(grant.email, 'joel@gmail.com');
    expect(grant.refreshToken, 'rt');
  });

  test('Google sign-in asks for mail, offline, with S256', () {
    final url = googleAuthUrl(
      redirect: 'http://127.0.0.1:1',
      verifier: 'v',
      state: 's',
      loginHint: 'joel@gmail.com',
    );
    expect(url.host, 'accounts.google.com');
    expect(url.queryParameters['scope'], contains('https://mail.google.com/'));
    expect(url.queryParameters['access_type'], 'offline');
    expect(url.queryParameters['code_challenge_method'], 'S256');
    expect(url.queryParameters['state'], 's');
    expect(url.queryParameters['login_hint'], 'joel@gmail.com');
  });

  test('refreshes the access token once, then reuses it', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      expect(req.bodyFields['grant_type'], 'refresh_token');
      expect(req.bodyFields['refresh_token'], 'rt');
      expect(req.bodyFields['scope'], contains('IMAP.AccessAsUser.All'));
      return http.Response(
        jsonEncode({'access_token': 'fresh', 'expires_in': 3600}),
        200,
      );
    });
    final a = await mailAccessToken(
      MailSignIn.microsoft,
      'cache@outlook.com',
      'rt',
      httpClient: client,
    );
    final b = await mailAccessToken(
      MailSignIn.microsoft,
      'cache@outlook.com',
      'rt',
      httpClient: client,
    );
    expect([a, b], ['fresh', 'fresh']);
    expect(calls, 1);
  });

  test('a revoked sign-in asks to sign in again', () async {
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'error': 'invalid_grant'}), 400),
    );
    expect(
      mailAccessToken(
        MailSignIn.google,
        'gone@gmail.com',
        'rt',
        httpClient: client,
      ),
      throwsA(
        isA<MailSignInError>().having(
          (e) => e.message,
          'message',
          contains('Sign in again'),
        ),
      ),
    );
  });

  test('a signed-in account keeps its provider when saved', () {
    const a = MailAccountConfig(
      email: 'joel@gmail.com',
      password: 'rt',
      imapHost: 'imap.gmail.com',
      smtpHost: 'smtp.gmail.com',
      signIn: 'google',
    );
    final back = MailAccountConfig.fromJson(
      jsonDecode(jsonEncode(a.toJson())) as Map,
    );
    expect(back.oauth, MailSignIn.google);
    expect(back.copyWith(name: 'J').oauth, MailSignIn.google);
    expect(MailAccountConfig.fromJson(const {'email': 'x@y.z'}).oauth, isNull);
  });

  test('id token claims read even without padding', () {
    expect(idTokenClaims(idToken({'email': 'a@b.c'}))['email'], 'a@b.c');
    expect(idTokenClaims('garbage'), isEmpty);
  });
}
