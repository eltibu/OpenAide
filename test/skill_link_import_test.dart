import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/workspace/skill_files.dart';

void main() {
  testWidgets('Import from link: the server reads the link, then a preview', (
    tester,
  ) async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    String? askedFor;
    String? previewed;
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    addTearDown(() => tester.runAsync(server.close));
    server.listen((req) async {
      Object? reply;
      switch (req.uri.path) {
        case '/api/v1/skills/load/url':
          askedFor = (jsonDecode(await utf8.decodeStream(req)) as Map)['url'];
          reply = [
            {'id': 'pdf-tools', 'name': 'PDF tools', 'content': '# PDF'},
          ];
        case '/api/v1/skills/import/preview':
          previewed = await utf8.decodeStream(req);
          reply = [
            {'index': 0, 'id': 'pdf-tools', 'name': 'PDF tools'},
          ];
        default:
          req.response.statusCode = 404;
      }
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(reply));
      await req.response.close();
    });
    final client = OpenWebUiClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const SkillImportScreen(fromLink: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Import from link'), findsWidgets);
    await tester.enterText(
      find.byType(TextField),
      'https://github.com/someone/skills',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await settle();

    expect(askedFor, 'https://github.com/someone/skills');
    expect(previewed, contains('filename="skills.json"'));
    expect(previewed, contains('"id":"pdf-tools"'));
    expect(find.text('PDF tools'), findsWidgets);
    expect(find.text('Import selected'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });
}
