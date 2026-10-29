import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/provider_models.dart';

void main() {
  test('only llama.cpp and LM Studio connections are managed', () {
    final c = providerConnections({
      'ENABLE_OPENAI_API': true,
      'OPENAI_API_BASE_URLS': ['https://api.openai.com/v1', 'http://box:8080'],
      'OPENAI_API_CONFIGS': {
        '0': {'provider': ''},
        '1': {'provider': 'llama.cpp'},
      },
    });
    expect(c, [(idx: 1, url: 'http://box:8080', provider: 'llama.cpp')]);
    expect(providerConnections({'ENABLE_OPENAI_API': false}), isEmpty);
  });

  test('catalog entries, names and status as the web reads them', () {
    final m = providerModelsFrom({
      'data': [
        'zeta',
        {
          'id': 'alpha',
          'status': {'value': 'sleeping'},
        },
        {
          'key': 'beta',
          'loaded_instances': [
            {'id': 'beta:1'},
          ],
        },
      ],
    });
    expect(m.map(providerModelId), ['alpha', 'beta', 'zeta']);
    expect(providerModelStatus(m[0], 'llama.cpp'), 'sleeping');
    expect(providerModelStatus(m[1], 'lmstudio'), 'loaded');
    expect(providerModelStatus(m[2], 'lmstudio'), 'unloaded');
    expect(providerModelStatus(m[2], 'llama.cpp'), 'available');
  });

  testWidgets('Load Model and Unload Model reach the server', (tester) async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    var loaded = false;
    final calls = <String>[];
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    addTearDown(() => tester.runAsync(server.close));
    server.listen((req) async {
      final body = req.method == 'POST' ? await utf8.decodeStream(req) : '';
      calls.add('${req.method} ${req.uri.path} $body'.trim());
      Object? reply = {'ok': true};
      switch (req.uri.path) {
        case '/openai/models/1/catalog':
          reply = {
            'data': [
              {
                'id': 'qwen',
                'status': {'value': loaded ? 'loaded' : 'unloaded'},
              },
            ],
          };
        case '/openai/models/1/load':
          loaded = true;
        case '/openai/models/1/unload':
          loaded = false;
      }
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(reply));
      await req.response.close();
    });
    final client = OpenWebUiClient(baseUrl: 'http://127.0.0.1:${server.port}');
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
          home: const ProviderModelsScreen(
            connections: [
              (idx: 1, url: 'http://box:8080', provider: 'llama.cpp'),
            ],
          ),
        ),
      ),
    );
    await settle();
    expect(find.text('qwen'), findsOneWidget);
    expect(find.text('unloaded'), findsOneWidget);

    await tester.tap(find.byTooltip('Load Model'));
    await settle();
    expect(calls, contains('POST /openai/models/1/load {"model":"qwen"}'));
    expect(find.text('loaded'), findsOneWidget);

    await tester.tap(find.byTooltip('Unload Model'));
    await settle();
    expect(calls, contains('POST /openai/models/1/unload {"model":"qwen"}'));
    expect(find.text('unloaded'), findsOneWidget);
    expect(find.byTooltip('Delete Model'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });
}
