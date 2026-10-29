// Runs against a real Open WebUI server; see server_sync_test.dart. The
// test's fake model answers "You said: ...".
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/phone/assist_panel.dart';

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

  testWidgets('the panel over other apps asks and shows the answer', (
    tester,
  ) async {
    HttpOverrides.global = null;
    final launched = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(const MethodChannel('nexus/launch'), (
      call,
    ) async {
      launched.add(call.method);
      return null;
    });
    final client = OpenWebUiClient(baseUrl: url!);
    await tester.runAsync(() => client.signIn(email!, password!));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(
            () => _Session(Session(serverUrl: url, token: client.token!)),
          ),
        ],
        child: const AssistPanelApp(listenFirst: false),
      ),
    );
    Future<void> wait(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await wait(() => find.byType(TextField).evaluate().isNotEmpty);
    expect(find.text('Open in app'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hello from the panel');
    await tester.tap(find.byTooltip('Send'));
    await wait(
      () => find
          .textContaining('You said: hello from the panel')
          .evaluate()
          .isNotEmpty,
    );
    expect(find.textContaining('You said: hello from the panel'), findsWidgets);

    // Open in app carries the chat on in the full app.
    await tester.tap(find.text('Open in app'));
    await tester.pump();
    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    expect(launched, containsAll(['openApp', 'close']));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }, skip: skip != null);
}
