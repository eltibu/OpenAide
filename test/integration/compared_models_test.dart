// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/chat/chat_screen.dart';

class _Session extends SessionNotifier {
  _Session(this.session);
  final Session session;
  @override
  Future<Session?> build() async => session;
}

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  testWidgets('comparing: each model\'s picture, tap one to see it', (
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
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(
          () => _Session(Session(serverUrl: url, token: client.token!)),
        ),
      ],
    );
    await tester.runAsync(() => container.read(sessionProvider.future));
    final models = (await tester.runAsync(
      () => container.read(modelsProvider.future),
    ))!;
    String name(String id) => models.firstWhere((m) => m.id == id).name;
    container.read(chatControllerProvider.notifier)
      ..selectModel('fake')
      ..setCompare(['fake2']);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const Scaffold(body: ComparedModels()),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byTooltip('Get information on ${name('fake2')} in the UI'),
      findsOneWidget,
    );
    expect(find.text(name('fake')), findsOneWidget);
    await tester.tap(
      find.byTooltip('Get information on ${name('fake2')} in the UI'),
    );
    await tester.pump();
    expect(find.text(name('fake2')), findsOneWidget);
    expect(find.text(name('fake')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    // Let the chat's own timers run out before it goes.
    await tester.pump(const Duration(minutes: 5));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    container.dispose();
  }, skip: skip != null);
}
