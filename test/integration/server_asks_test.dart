// Runs against a real Open WebUI server; see tool_approval_test.dart. In a
// temporary chat the server asks over the live connection, and the app
// answers there. Needs Tool Permissions on (Admin > Settings > Chat), "ask" as the person's tool
// approval mode, native function calling, and the test's fake model: it
// calls ask_user for "ask me" and get_current_timestamp for "time", and
// answers a tool result with "Tool said: …".
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/core/api/chat_socket.dart';
import 'package:nexus_assistant/features/chat/server_asks.dart';

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

  test('a temporary chat asks over the live connection', () async {
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
    final models = await container.read(modelsProvider.future);
    await container.read(userSettingsProvider.future);
    final socket = container.read(chatSocketProvider);
    await socket.ready(timeout: const Duration(seconds: 10));
    final calls = <SocketCall>[];
    final sub = socket.calls.listen((c) {
      calls.add(c);
      if (c.type == 'request:user_input') {
        final q = (c.body['questions'] as List).first as Map;
        c.reply({
          'status': 'answered',
          'answers': {
            '${q['id'] ?? 'q0'}': {
              'type': 'option',
              'option_index': 1,
              'label': 'Blue',
              'description': '',
            },
          },
        });
      } else if (c.type == 'confirmation') {
        c.reply(false);
      } else {
        c.reply(cantRunHere);
      }
    });
    addTearDown(sub.cancel);
    final controller = container.read(chatControllerProvider.notifier)
      ..selectModel(models.first.id)
      ..newChat(temporary: true);
    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      for (var i = 0; i < 300; i++) {
        if (!container.read(chatControllerProvider).streaming) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      fail('The reply never finished');
    }

    String last() =>
        container.read(chatControllerProvider).messages.last.content;

    await controller.send('Please ask me something');
    await settle();
    expect(calls.map((c) => c.type), contains('request:user_input'));
    expect(last(), contains('Blue'));

    // A tool to allow: denied here, and the reply still finishes.
    await controller.send('What time is it?');
    await settle();
    final ask = calls.lastWhere((c) => c.type == 'confirmation');
    expect((ask.body['tool_call'] as Map)['name'], 'get_current_timestamp');
    expect(container.read(chatControllerProvider).streaming, isFalse);
  }, skip: skip);

  test('elicitation forms and input options read as the web reads them', () {
    final fields = formFields({
      'requestedSchema': {
        'properties': {
          'name': {'type': 'string', 'title': 'Name'},
          'age': {'type': 'integer'},
          'color': {
            'type': 'string',
            'enum': ['r', 'b'],
            'enumNames': ['Red', 'Blue'],
          },
          'tags': {
            'type': 'array',
            'items': {
              'anyOf': [
                {'const': 'a', 'title': 'A'},
              ],
            },
            'minItems': 1,
          },
        },
        'required': ['name'],
      },
    });
    expect(fields.map((f) => f.name), ['name', 'age', 'color', 'tags']);
    expect(fields.every((f) => f.supported), isTrue);
    expect(fields[2].options.map((o) => o.title), ['Red', 'Blue']);
    expect(formContent(fields, {'name': ''}), isNull);
    expect(
      formContent(fields, {'name': 'Jo', 'age': '4', 'tags': <String>[]}),
      {'name': 'Jo', 'age': 4},
    );
    expect(formContent(fields, {'name': 'Jo', 'age': 'x'}), isNull);
    expect(inputOption({'label': 'One', 'value': '1'}), (
      label: 'One',
      value: '1',
    ));
    expect(inputOption('x'), (label: 'x', value: 'x'));
  });
}
