// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/settings/settings_api.dart';
import 'package:nexus_assistant/features/settings/usage_sync.dart';

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
  late OpenWebUiClient client;
  late ProviderContainer container;

  setUp(() async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    if (url == null) return;
    client = OpenWebUiClient(baseUrl: url);
    await client.signIn(email!, password!);
    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(
          () => _Session(Session(serverUrl: url, token: client.token!)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    await container.read(modelsProvider.future);
  });

  test('Generate message pair saves your message and an empty answer, '
      'with no model asked; the heart is saved too', () async {
    final controller = container.read(chatControllerProvider.notifier)
      ..selectModel('fake')
      ..newChat();
    expect(await controller.createMessagePair('A pair'), isTrue);
    final id = container.read(chatControllerProvider).chat!.id;
    addTearDown(() => client.deleteChat(id));
    final saved = await client.chat(id);
    final thread = saved.thread;
    expect(thread.map((m) => m.role), ['user', 'assistant']);
    expect(thread.first.content, 'A pair');
    expect(thread.last.content, startsWith('[RESPONSE] '));
    expect(thread.last.model, 'fake');

    await container
        .read(chatControllerProvider.notifier)
        .toggleFavorite(container.read(chatControllerProvider).messages.last);
    final again = await client.chat(id);
    expect(again.thread.last.extra['favorite'], isTrue);
  }, skip: skip);

  test("a note's chats: listed, opened with the chosen model kept", () async {
    final note = await client.send(
      'POST',
      '/api/v1/notes/create',
      body: {
        'title': 'Chat note',
        'data': {
          'content': {'md': 'hello'},
        },
      },
    ) as Map;
    final noteId = '${note['id']}';
    addTearDown(() => client.send('DELETE', '/api/v1/notes/$noteId/delete'));
    final made = await client.send('POST', '/api/v1/notes/$noteId/chat') as Map;
    final chats =
        await client.send('GET', '/api/v1/notes/$noteId/chats') as List;
    expect(chats.map((c) => (c as Map)['id']), contains(made['id']));
    final controller = container.read(chatControllerProvider.notifier)
      ..selectModel('fake');
    await controller.open('${made['id']}');
    final state = container.read(chatControllerProvider);
    expect(state.modelId, 'fake');
    expect('${state.params['system']}', contains(noteId));
    await client.deleteChat('${made['id']}');
  }, skip: skip);

  test('usage stats export pages through every chat', () async {
    final pages = <int>[];
    final items = await exportUsageStats(
      client,
      onPage: (_, done, total) => pages.add(done),
    );
    expect(pages, isNotEmpty);
    expect(items.length, pages.last);
  }, skip: skip);

  // A throwaway account, so tests running alongside keep their sign-in.
  test('change password', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final temp = 'pw$stamp@example.com';
    final made = await client.send(
      'POST',
      '/api/v1/auths/add',
      body: {
        'name': 'Password test',
        'email': temp,
        'password': 'first-Pass1',
        'role': 'user',
      },
    ) as Map;
    addTearDown(() => client.send('DELETE', '/api/v1/users/${made['id']}'));
    final user = OpenWebUiClient(baseUrl: url!);
    await user.signIn(temp, 'first-Pass1');
    await SettingsApi(user).updatePassword('first-Pass1', 'second-Pass2');
    await OpenWebUiClient(baseUrl: url).signIn(temp, 'second-Pass2');
    await expectLater(
      OpenWebUiClient(baseUrl: url).signIn(temp, 'first-Pass1'),
      throwsA(anything),
    );
  }, skip: skip);
}
