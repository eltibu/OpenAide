import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/auth/login_screen.dart';
import 'package:nexus_assistant/features/auth/sign_in_steps.dart';

/// A stand-in server: sign-in asks for a code (or says pending), the code
/// 123456 signs in, and setting up hands out recovery codes.
Future<HttpServer> fakeServer({required String firstStep}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final body = req.method == 'POST'
        ? jsonDecode(await utf8.decodeStream(req)) as Map
        : const {};
    Object? reply;
    var status = 200;
    switch (req.uri.path) {
      case '/api/config':
        reply = {'name': 'Fake', 'version': '1'};
      case '/api/v1/auths/signin':
      case '/api/v1/auths/ldap':
        reply = firstStep == 'pending'
            ? {'next_step': 'pending'}
            : {
                'next_step': firstStep,
                'challenge_token': 'c' * 24,
                'expires_in': 300,
              };
      case '/api/v1/auths/mfa/verify':
        if (body['code'] == '123456' && body['challenge_token'] == 'c' * 24) {
          reply = {'token': 'jwt-ok', 'id': 'u1'};
        } else {
          status = 400;
          reply = {'detail': 'Invalid code'};
        }
      case '/api/v1/auths/mfa/enroll/confirm':
        reply = {
          'token': 'jwt-new',
          'id': 'u1',
          'recovery_codes': ['aaaa-bbbb', 'cccc-dddd'],
        };
      case '/api/v1/auths/':
        reply =
            req.headers.value('authorization')?.startsWith('Bearer jwt') == true
            ? {'id': 'u1', 'name': 'Joel', 'role': 'user'}
            : null;
        if (reply == null) status = 401;
      default:
        status = 404;
        reply = {'detail': 'Not found'};
    }
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(reply));
    await req.response.close();
  });
  return server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding fakes every web request; these talk to a real one.
  HttpOverrides.global = null;
  final stored = <String, String>{};
  setUp(() {
    stored.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? const {};
            switch (call.method) {
              case 'write':
                stored['${args['key']}'] = '${args['value']}';
              case 'read':
                return stored['${args['key']}'];
              case 'delete':
                stored.remove('${args['key']}');
            }
            return null;
          },
        );
  });

  test('a wrong code keeps the step; the right one signs in', () async {
    final server = await fakeServer(firstStep: 'verify');
    addTearDown(server.close);
    final url = 'http://127.0.0.1:${server.port}';
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    final notifier = container.read(sessionProvider.notifier);
    await notifier.signInWithPassword(url, 'j@x.io', 'pw');
    var step = container.read(sessionProvider).error as SignInStep;
    expect(step.next, 'verify');
    await notifier.answerStep(step, '000000');
    step = container.read(sessionProvider).error as SignInStep;
    expect(step.next, 'verify');
    expect('${step.reply['error']}', contains('Invalid code'));
    await notifier.answerStep(step, '123456');
    final session = container.read(sessionProvider).value!;
    expect(session.token, 'jwt-ok');
    expect(session.userName, 'Joel');
    expect(stored['token'], 'jwt-ok');
  });

  test('setting up shows the recovery codes before signing in', () async {
    final server = await fakeServer(firstStep: 'enroll');
    addTearDown(server.close);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    final notifier = container.read(sessionProvider.notifier);
    await notifier.signInWithLdap(
      'http://127.0.0.1:${server.port}',
      'joel',
      'pw',
    );
    var step = container.read(sessionProvider).error as SignInStep;
    expect(step.next, 'enroll');
    await notifier.answerStep(step, '654321');
    step = container.read(sessionProvider).error as SignInStep;
    expect(step.next, 'codes');
    expect(step.recoveryCodes, ['aaaa-bbbb', 'cccc-dddd']);
    await notifier.finishStep(step);
    expect(container.read(sessionProvider).value!.token, 'jwt-new');
  });

  test('a pending account says so', () async {
    final server = await fakeServer(firstStep: 'pending');
    addTearDown(server.close);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    await container
        .read(sessionProvider.notifier)
        .signInWithPassword('http://127.0.0.1:${server.port}', 'j@x.io', 'pw');
    final step = container.read(sessionProvider).error as SignInStep;
    expect(step.next, 'pending');
    expect('$step', contains('approve'));
    container.read(sessionProvider.notifier).restart();
    expect(container.read(sessionProvider).value, isNull);
  });

  test('recovery codes file', () {
    expect(recoveryCodesFile(['a', 'b']), endsWith('a\nb\n'));
  });

  testWidgets('the form offers LDAP and creating an account', (t) async {
    await t.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LoginScreen())),
    );
    await t.pumpAndSettle();
    await t.ensureVisible(find.text("Don't have an account? Sign up"));
    await t.pumpAndSettle();
    await t.tap(find.text("Don't have an account? Sign up"));
    await t.pump();
    expect(find.text('Confirm Password'), findsOneWidget);
    expect(find.text('Create Account'), findsOneWidget);
    await t.ensureVisible(find.text('LDAP'));
    await t.pumpAndSettle();
    await t.tap(find.text('LDAP'));
    await t.pump();
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Confirm Password'), findsNothing);
  });

  testWidgets('a code step shows why the last code failed', (t) async {
    final step = SignInStep(OpenWebUiClient(baseUrl: 'http://x'), {
      'next_step': 'verify',
      'challenge_token': 'c' * 24,
      'error': 'Invalid code',
    });
    await t.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: TwoStepScreen(step: step)),
      ),
    );
    await t.pump();
    expect(find.text('Invalid code'), findsOneWidget);
    expect(find.text('Use a recovery code'), findsOneWidget);
    await t.tap(find.text('Use a recovery code'));
    await t.pump();
    expect(find.text('Recovery code'), findsOneWidget);
  });
}
