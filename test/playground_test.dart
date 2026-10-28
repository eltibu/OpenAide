import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/models/model_info.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';
import 'package:nexus_assistant/features/playground/playground_screen.dart';

class _FakeClient extends OpenWebUiClient {
  _FakeClient() : super(baseUrl: 'http://x');
  final sent = <(String, String, Object?)>[];

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    sent.add((method, path, body));
    if (path == '/api/v1/images/models') {
      return [
        {'id': 'dall-e-3', 'name': 'DALL·E 3'},
      ];
    }
    if (path == '/api/v1/images/generations') {
      return [
        {'url': 'data:image/png;base64,iVBORw0KGgo='},
      ];
    }
    return null;
  }
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

Widget _app(OpenWebUiClient client, {bool images = true}) => ProviderScope(
  overrides: [
    clientProvider.overrideWithValue(client),
    serverConfigProvider.overrideWith(
      (ref) async => {
        'features': {'enable_image_generation': images},
      },
    ),
    modelsProvider.overrideWith(
      (ref) async => [ModelInfo(id: 'nexus', name: 'Nexus', raw: {})],
    ),
  ],
  child: MaterialApp(
    theme: nexusTheme(Brightness.light),
    home: const PlaygroundScreen(),
  ),
);

void main() {
  test('exports the messages the way the API takes them', () {
    final json = jsonDecode(
      playgroundJson('nexus', ' Be brief ', [
        (role: 'user', content: 'Hi'),
        (role: 'assistant', content: ''),
      ]),
    );
    expect(json, {
      'model': 'nexus',
      'messages': [
        {'role': 'system', 'content': 'Be brief'},
        {'role': 'user', 'content': 'Hi'},
      ],
    });
  });

  test('exports plain text', () {
    expect(
      playgroundText('', [
        (role: 'user', content: 'Hi'),
        (role: 'assistant', content: 'Hello'),
      ]),
      '### USER\nHi\n\n### ASSISTANT\nHello',
    );
  });

  testWidgets('has chat, completions and images', (tester) async {
    _tall(tester);
    final client = _FakeClient();
    await tester.pumpWidget(_app(client));
    await tester.pumpAndSettle();
    expect(find.text('Copy JSON'), findsOneWidget);

    await tester.tap(find.text('Completions'));
    await tester.pumpAndSettle();
    expect(
      find.text('Write the start; the model carries on from there'),
      findsOneWidget,
    );

    await tester.tap(find.text('Images'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Describe the picture'),
      'a cat',
    );
    await tester.tap(find.text('Make'));
    await tester.pumpAndSettle();
    final (method, path, body) = client.sent.last;
    expect((method, path), ('POST', '/api/v1/images/generations'));
    expect(body, {'prompt': 'a cat', 'n': 1});
    expect(find.byTooltip('Save to phone'), findsOneWidget);
  });

  testWidgets('says when image making is off', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(_FakeClient(), images: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Images'));
    await tester.pumpAndSettle();
    expect(find.textContaining('isn\'t turned on'), findsOneWidget);
  });

  test('playground controls go as request fields', () {
    expect(
      playgroundParams({
        'temperature': 0.2,
        'top_k': null,
        'custom_params': {'seed_text': 'x'},
      }),
      {'temperature': 0.2, 'seed_text': 'x'},
    );
  });
}
