// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/chat/folder_home.dart';

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

  test("a folder's icon is saved as the web saves it", () async {
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
    await client.createFolder('Icon test');
    final folder = (await client.folders()).firstWhere(
      (f) => f.name == 'Icon test',
    );
    try {
      expect(
        folderEmoji(
          await container.read(folderDetailProvider(folder.id).future),
        ),
        isNull,
      );
      await client.send(
        'POST',
        '/api/v1/folders/${folder.id}/update',
        body: {
          'meta': {'icon': 'rocket'},
        },
      );
      container.invalidate(folderDetailProvider(folder.id));
      final detail = await container.read(
        folderDetailProvider(folder.id).future,
      );
      expect(folderEmoji(detail), '🚀');
      expect(detail['name'], 'Icon test');
      expect(await client.folderChats(folder.id), isEmpty);
    } finally {
      await client.deleteFolder(folder.id);
    }
  }, skip: skip);
}
