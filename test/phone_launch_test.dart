import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/phone/app_lock.dart';
import 'package:nexus_assistant/features/phone/phone_launch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reads what Android hands over', () {
    final l = PhoneLaunch.fromMap({
      'kind': 'share',
      'text': 'look at this',
      'files': ['/c/a.png', 3],
    })!;
    expect(l.kind, 'share');
    expect(l.text, 'look at this');
    expect(l.files, ['/c/a.png']);
    expect(PhoneLaunch.fromMap(null), isNull);
    expect(PhoneLaunch.fromMap({'text': 'x'}), isNull);
  });

  test(
    'the assistant button follows the setting; others do their own thing',
    () {
      const assist = PhoneLaunch('assist');
      expect(launchAction(assist, null), 'call');
      expect(launchAction(assist, {assistantOpensKey: 'dictate'}), 'dictate');
      expect(launchAction(assist, {assistantOpensKey: 'chat'}), 'new');
      expect(
        launchAction(const PhoneLaunch('share'), {assistantOpensKey: 'chat'}),
        'share',
      );
      expect(
        launchAction(const PhoneLaunch('call'), {assistantOpensKey: 'chat'}),
        'call',
      );
    },
  );

  test('locks only when set and away long enough', () {
    expect(lockDue(null, const Duration(hours: 1)), isFalse);
    expect(lockDue(60, null), isFalse);
    expect(lockDue(60, const Duration(seconds: 59)), isFalse);
    expect(lockDue(60, const Duration(seconds: 60)), isTrue);
    expect(lockDue(0, Duration.zero), isTrue);
  });

  testWidgets('the gate covers the app until the phone unlocks', (t) async {
    final calls = <String>[];
    var unlockAnswer = false;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(phoneChannel, (
      call,
    ) async {
      calls.add(call.method);
      return call.method == 'unlock' ? unlockAnswer : null;
    });
    const storage = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(storage, (
      call,
    ) async {
      return call.method == 'read' ? '60' : null;
    });
    await t.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: AppLockGate(child: Text('secret'))),
      ),
    );
    await t.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.text('OpenAide is locked'), findsOneWidget);
    expect(calls, contains('unlock'));
    unlockAnswer = true;
    await t.tap(find.text('Unlock'));
    await t.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.text('OpenAide is locked'), findsNothing);
    expect(find.text('secret'), findsOneWidget);
  });
}
