// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/visible_controls.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  testWidgets('an admin hides a control from users and shows it again', (
    tester,
  ) async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    final client = OpenWebUiClient(baseUrl: url!);
    await tester.runAsync(() => client.signIn(email!, password!));
    Future<Map<String, bool>> hidden() async =>
        visibilityFrom(await tester.runAsync(client.config));
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const VisibleControlsScreen(),
        ),
      ),
    );
    await settle();
    final fork = find.widgetWithText(SwitchListTile, 'Fork chat');
    await tester.scrollUntilVisible(fork, 300);
    await tester.ensureVisible(fork);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(fork).value, isTrue);

    await tester.tap(fork);
    await settle();
    expect((await hidden())['chat.fork'], isFalse);

    await tester.tap(fork);
    await settle();
    expect((await hidden()).containsKey('chat.fork'), isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }, skip: skip != null);
}
