import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/channels/channel_manage.dart';
import 'package:nexus_assistant/features/channels/channels_api.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart';

Map<String, dynamic> _app(String id, String name) => {
  'id': id,
  'name': name,
  'is_active': true,
  'configured': true,
  'data': {
    'manifest': {'description': '$name helps out'},
  },
};

class _FakeClient extends OpenWebUiClient {
  _FakeClient() : super(baseUrl: 'http://x');
  final joined = <String>{'bot'};
  final calls = <String>[];

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    calls.add('$method $path');
    if (path.endsWith('/members')) {
      return {
        'users': [
          {'id': 'u1', 'name': 'Joel'},
        ],
      };
    }
    if (path == '/api/v1/apps') {
      return [_app('bot', 'Bot'), _app('helper', 'Helper')];
    }
    if (path.endsWith('/apps') && method == 'GET') {
      return [
        for (final id in joined) _app(id, id == 'bot' ? 'Bot' : 'Helper'),
      ];
    }
    if (path.endsWith('/apps') && method == 'POST') {
      joined.add((body as Map)['app_id'] as String);
      return {};
    }
    if (method == 'DELETE') {
      joined.remove(path.split('/').last);
      return {'removed': true};
    }
    return {};
  }
}

void main() {
  testWidgets('a channel manager adds and removes apps', (tester) async {
    final client = _FakeClient();
    final channel = Channel.fromJson({
      'id': 'c1',
      'name': 'general',
      'is_manager': true,
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverConfigProvider.overrideWith(
            (ref) async => {
              'features': {'enable_apps': true},
            },
          ),
        ],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: ChannelMembersScreen(
            api: ChannelsApi(client),
            channel: channel,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Bot'), findsOneWidget);
    expect(find.text('Helper'), findsNothing);

    await tester.tap(find.text('Add an app'));
    await tester.pumpAndSettle();
    // Only apps that haven't joined are offered.
    expect(find.text('Bot'), findsOneWidget);
    await tester.tap(find.text('Helper'));
    await tester.pumpAndSettle();
    expect(client.calls, contains('POST /api/v1/channels/c1/apps'));
    expect(find.text('Helper'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove app').first);
    await tester.pumpAndSettle();
    expect(client.calls, contains('DELETE /api/v1/channels/c1/apps/bot'));
    expect(find.text('Bot'), findsNothing);
  });

  testWidgets('no Apps section when the server has apps off', (tester) async {
    final client = _FakeClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverConfigProvider.overrideWith((ref) async => {'features': {}}),
        ],
        child: MaterialApp(
          home: ChannelMembersScreen(
            api: ChannelsApi(client),
            channel: Channel.fromJson({'id': 'c1', 'name': 'general'}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Apps'), findsNothing);
    expect(client.calls.where((c) => c.contains('apps')), isEmpty);
  });
}
