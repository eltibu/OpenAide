import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/groups_screen.dart';

class _FakeClient extends OpenWebUiClient {
  _FakeClient() : super(baseUrl: 'http://x');
  final calls = <(String, String, Object?)>[];

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    calls.add((method, path, body));
    if (path.endsWith('/permissions/defaults')) {
      return {
        'chat': {'delete': true, 'share': true},
        'features': {'notes': true},
      };
    }
    if (path.endsWith('/members')) {
      return {
        'items': [
          {'id': 'u1', 'name': 'Ana', 'email': 'ana@x'},
        ],
        'total': 1,
      };
    }
    return true;
  }
}

void main() {
  test('a group gives only what it names', () {
    final base = {
      'chat': {'delete': true, 'share': true},
      'features': {'notes': true},
    };
    expect(
      permissionsFor(base, {
        'chat': {'share': true},
      }, fill: true),
      {
        'chat': {'delete': false, 'share': true},
        'features': {'notes': false},
      },
    );
    expect(permissionLabel('public_models'), 'Public models');
    expect(permissionLabel('stt'), 'Speech to text');
  });

  testWidgets('edits a group\'s permissions and members', (tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final client = _FakeClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const GroupEditor(
            group: {
              'id': 'g1',
              'name': 'Team',
              'description': '',
              'permissions': {
                'chat': {'share': true},
              },
              'data': {
                'config': {'share': 'members'},
              },
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Members (1)'), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget);

    await tester.tap(find.text('Notes'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final (_, path, body) = client.calls.lastWhere((c) => c.$1 == 'POST');
    expect(path, '/api/v1/groups/id/g1/update');
    expect((body as Map)['permissions'], {
      'chat': {'delete': false, 'share': true},
      'features': {'notes': true},
    });
    expect(body['data'], {
      'config': {'share': 'members'},
    });

    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    final remove = client.calls.lastWhere((c) => c.$1 == 'POST');
    expect(remove.$2, '/api/v1/groups/id/g1/users/remove');
    expect(remove.$3, {
      'user_ids': ['u1'],
    });
  });
}
