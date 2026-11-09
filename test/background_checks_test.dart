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

  test('instant notifications: on by default, can be turned off', () async {
    final calls = <MethodCall>[];
    var instant = true;
    var free = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nexus/notify'), (
          c,
        ) async {
          calls.add(c);
          switch (c.method) {
            case 'instantAvailable':
              return true;
            case 'instantOn':
              return instant;
            case 'instant':
              instant = (c.arguments as Map)['enabled'] as bool;
            case 'batteryFree':
              return free;
            case 'askBattery':
              free = true;
          }
          return null;
        });
    expect(await instantAvailable(), isTrue);
    expect(await instantOn(), isTrue);
    await setInstant(false);
    expect(await instantOn(), isFalse);
    expect(calls.firstWhere((c) => c.method == 'instant').arguments, {
      'enabled': false,
    });
    expect(await batteryFree(), isFalse);
    await askBatteryFree();
    expect(await batteryFree(), isTrue);
  });

  test('off the phone, instant notifications are simply not there', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nexus/notify'), null);
    expect(await instantAvailable(), isFalse);
    expect(await instantOn(), isFalse);
    expect(await batteryFree(), isTrue);
  });
}
