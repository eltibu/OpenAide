// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/user_extras.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  testWidgets('an admin sees what someone can reach and their chats', (
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
    final users = await tester.runAsync(
      () => client.send('GET', '/api/v1/users/all'),
    );
    final other = ((users as Map)['users'] as List).cast<Map>().firstWhere(
      (u) => u['role'] != 'admin',
    );
    Widget app(Widget home) => ProviderScope(
      overrides: [clientProvider.overrideWithValue(client)],
      child: MaterialApp(theme: nexusTheme(Brightness.light), home: home),
    );
    await tester.pumpWidget(
      app(UserPreviewScreen(userId: '${other['id']}', name: 'X')),
    );
    for (var i = 0; i < 20 && find.text('Models').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Groups'), findsOneWidget);

    await tester.pumpWidget(
      app(UserChatsScreen(userId: '${other['id']}', name: 'X')),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(find.text("X's Chats"), findsOneWidget);
    expect(find.textContaining("Couldn't load"), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }, skip: skip != null);
}
