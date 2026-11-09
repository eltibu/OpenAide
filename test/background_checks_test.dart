import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/reply_notify.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('closed-app checks get the sign-in, and stop on sign-out', () async {
    final calls = <MethodCall>[];
    var on = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nexus/notify'), (
          c,
        ) async {
          calls.add(c);
          if (c.method == 'background') {
            on = (c.arguments as Map)['enabled'] as bool;
          }
          if (c.method == 'backgroundOn') return on;
          return null;
        });
    expect(await backgroundChecksOn(), isFalse);
    await setBackgroundChecks(
      true,
      baseUrl: 'https://chat.example',
      token: 't',
      cookie: 'c=1',
    );
    expect(await backgroundChecksOn(), isTrue);
    expect(calls[1].arguments, {
      'enabled': true,
      'baseUrl': 'https://chat.example',
      'token': 't',
      'cookie': 'c=1',
    });
    await setBackgroundChecks(false);
    expect(await backgroundChecksOn(), isFalse);
  });

  test('Instant is set only when asked, and only where the build has it',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nexus/notify'), (
          c,
        ) async {
          calls.add(c);
          if (c.method == 'instantAvailable') return true;
          if (c.method == 'instantOn') return true;
          return null;
        });
    expect(await instantChecksAvailable(), isTrue);
    expect(await instantChecksOn(), isTrue);
    await setBackgroundChecks(
      true,
      baseUrl: 'https://chat.example',
      token: 't',
      instant: true,
    );
    expect((calls.last.arguments as Map)['instant'], isTrue);
    // A new sign-in handed over at start leaves Instant as it is.
    await setBackgroundChecks(true, baseUrl: 'https://chat.example', token: 't');
    expect((calls.last.arguments as Map).containsKey('instant'), isFalse);
  });

  test('without the phone side, Instant reads as off', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nexus/notify'), null);
    expect(await instantChecksAvailable(), isFalse);
    expect(await instantChecksOn(), isFalse);
  });

  test('turned-down notifications open Android settings', () async {
    final calls = <String>[];
    var granted = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nexus/notify'), (
          c,
        ) async {
          calls.add(c.method);
          if (c.method == 'ask' || c.method == 'allowed') return granted;
          return null;
        });
    expect(await allowNotifications(), isFalse);
    expect(calls, ['ask', 'openSettings']);
    calls.clear();
    granted = true;
    expect(await allowNotifications(), isTrue);
    expect(calls, ['ask', 'allowed']);
  });
}
