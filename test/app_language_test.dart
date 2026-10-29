import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/i18n/app_strings.dart';
import 'package:nexus_assistant/features/settings/language_settings.dart';

class _FakeClient extends OpenWebUiClient {
  _FakeClient() : super(baseUrl: 'http://x');
  Object? asked;

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    asked = body;
    return {
      'choices': [
        {
          'message': {
            'content':
                'Sure!\n```json\n{"Add people": "Añadir personas", '
                '"Other": "x"}\n```',
          },
        },
      ],
    };
  }
}

void main() {
  tearDown(() => AppStrings.instance.choose(null));

  testWidgets('the app shows the web\'s words in the chosen language', (
    tester,
  ) async {
    await tester.pumpWidget(
      AppStringsScope(
        child: const MaterialApp(home: Scaffold(body: T('Save'))),
      ),
    );
    expect(find.text('Save'), findsOneWidget);
    await tester.runAsync(() => AppStrings.instance.choose('es-ES'));
    await tester.pump();
    expect(find.text('Guardar'), findsOneWidget);
    expect(AppStrings.instance.locale, const Locale('es', 'ES'));
    await tester.runAsync(() => AppStrings.instance.choose(null));
    await tester.pump();
    expect(find.text('Save'), findsOneWidget);
  });

  test('every language the web has is offered', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final all = await AppStrings.languages();
    expect(all.length, greaterThan(50));
    expect(all.map((l) => l.code), containsAll(['es-ES', 'fr-FR', 'ja-JP']));
    expect(await AppStrings.appWords(), contains('Add people'));
  });

  test('the server model fills in phrases the web lacks', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final client = _FakeClient();
    final got = await translateWithServer(client, 'm', 'Español', [
      'Add people',
    ]);
    expect(got, {'Add people': 'Añadir personas'});
    expect((client.asked as Map)['stream'], false);
    await AppStrings.instance.choose('es-ES');
    expect(await AppStrings.instance.missing('es-ES'), contains('Add people'));
    await AppStrings.instance.addServerWords('es-ES', got);
    expect(tr('Add people'), 'Añadir personas');
  });

  test('a reply with no translations gives none', () {
    expect(parseTranslations('You said: ["a"]', ['a']), isEmpty);
    expect(parseTranslations('{"a": ""}', ['a']), isEmpty);
  });
}
