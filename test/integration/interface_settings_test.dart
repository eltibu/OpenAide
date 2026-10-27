// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/settings/settings_screen.dart';

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

  TestWidgetsFlutterBinding.ensureInitialized();

  test('Settings > Interface: new chats start temporary when asked', () async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(
          () => _Session(Session(serverUrl: url, token: client.token!)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    final api = container.read(settingsApiProvider);
    await api.patchUi({'temporaryChatByDefault': true});
    addTearDown(() => api.patchUi({'temporaryChatByDefault': false}));
    final ui = await container.read(uiSettingsProvider.future);
    expect(ui['temporaryChatByDefault'], true);

    // A fresh chat screen picks it up once settings load.
    container.read(chatControllerProvider);
    await container.read(userSettingsProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(chatControllerProvider).temporary, true);

    final controller = container.read(chatControllerProvider.notifier)
      ..newChat(temporary: false);
    expect(container.read(chatControllerProvider).temporary, false);
    controller.newChat();
    expect(container.read(chatControllerProvider).temporary, true);
  }, skip: skip);
}
