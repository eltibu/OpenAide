// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/ui_translations.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  testWidgets('an admin adds the server\'s own wording for a phrase', (
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
          home: const UiTranslationsScreen(),
        ),
      ),
    );
    await settle();
    // The add button slides in once the page has loaded.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Add translation'));
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Key').last,
      'New chat',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Value').last,
      'Fresh chat',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await settle();
    final config = await tester.runAsync(client.config);
    expect((config!['i18n'] as Map)['en-US'], {'New chat': 'Fresh chat'});

    // And taken away again.
    await tester.tap(find.byTooltip('Delete').last);
    await tester.pump();
    await tester.tap(find.text('Save'));
    await settle();
    final after = await tester.runAsync(client.config);
    expect((after!['i18n'] as Map?)?['en-US'], isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }, skip: skip != null);
}
