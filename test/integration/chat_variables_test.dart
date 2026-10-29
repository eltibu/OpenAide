// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/chat/chat_variables.dart';

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

  test('chat variables are asked for, used and kept with the chat', () async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    await client.send(
      'POST',
      '/api/v1/models/create',
      body: {
        'id': 'vars-test',
        'base_model_id': 'fake',
        'name': 'Vars test',
        'meta': <String, dynamic>{},
        'params': {
          'system':
              'Answer in {{chat.variables.lang | '
              'select:options=["French","Spanish"]:required}}.',
        },
      },
    );
    addTearDown(
      () => client.send(
        'POST',
        '/api/v1/models/model/delete',
        body: {'id': 'vars-test'},
      ),
    );
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(
          () => _Session(Session(serverUrl: url, token: client.token!)),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    final models = await container.read(modelsProvider.future);
    final fields = chatVariableFields(models, ['vars-test']);
    expect(fields.single['key'], 'lang');
    expect(fields.single['type'], 'select');
    expect(fields.single['required'], isTrue);
    expect(chatVariablesNeeded(fields, {}), isTrue);
    expect(chatVariablesNeeded(fields, {'lang': 'French'}), isFalse);

    final controller = container.read(chatControllerProvider.notifier)
      ..selectModel('vars-test');
    ChatState now() => container.read(chatControllerProvider);

    // A new chat: the answers go with the first message, then are saved.
    await controller.setVariables({'lang': 'French'});
    await controller.send('echo settings');
    expect(now().messages.last.content, contains('Answer in French.'));
    final id = now().chat!.id;
    for (var i = 0; i < 20; i++) {
      final saved = await client.chat(id);
      if (saved.variables['lang'] == 'French') break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect((await client.chat(id)).variables, {'lang': 'French'});

    // Changed later: saved on the chat and used from then on.
    await controller.setVariables({'lang': 'Spanish'});
    await controller.open(id);
    expect(now().variables, {'lang': 'Spanish'});
    await controller.send('echo settings');
    expect(now().messages.last.content, contains('Answer in Spanish.'));
  }, skip: skip);
}
