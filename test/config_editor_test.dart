import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/admin/config_editor.dart';

class _FakeClient extends OpenWebUiClient {
  _FakeClient(this.settings) : super(baseUrl: 'http://x');
  Map<String, dynamic> settings;
  final saved = <Object?>[];

  @override
  Future<dynamic> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (method == 'POST') {
      saved.add(body);
      settings = (body as Map).cast<String, dynamic>();
    }
    return settings;
  }
}

void main() {
  test('names settings the way people read them', () {
    expect(
      settingLabel('ENABLE_RAG_HYBRID_SEARCH'),
      'Enable RAG hybrid search',
    );
    expect(settingLabel('TOP_K_RERANKER'), 'Top K reranker');
    expect(
      settingLabel('IMAGES_OPENAI_API_BASE_URL'),
      'Images openai API base URL',
    );
  });

  test('hides keys and tokens but not token counts', () {
    expect(isSecretSetting('BRAVE_SEARCH_API_KEY'), isTrue);
    expect(isSecretSetting('CODE_EXECUTION_JUPYTER_AUTH_TOKEN'), isTrue);
    expect(isSecretSetting('YACY_PASSWORD'), isTrue);
    expect(isSecretSetting('BRAVE_SEARCH_CONTEXT_TOKENS'), isFalse);
    expect(isSecretSetting('RAG_TOKENIZER_MODEL'), isFalse);
    expect(isSecretSetting('CODE_EXECUTION_JUPYTER_AUTH'), isTrue);
    expect(isSecretSetting('AUTH_TYPE'), isFalse);
  });

  test('shows only the chosen engine\'s settings', () {
    const engines = {
      'WEB_SEARCH_ENGINE': {
        '': <String>[],
        'searxng': ['SEARXNG_'],
        'brave': ['BRAVE_SEARCH_'],
        'brave_llm_context': ['BRAVE_SEARCH_'],
      },
    };
    final data = {'WEB_SEARCH_ENGINE': 'brave_llm_context'};
    expect(hiddenByEngine('SEARXNG_QUERY_URL', data, engines), isTrue);
    expect(hiddenByEngine('BRAVE_SEARCH_API_KEY', data, engines), isFalse);
    expect(hiddenByEngine('WEB_SEARCH_RESULT_COUNT', data, engines), isFalse);
  });

  testWidgets('edits a nested settings part and saves all of it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final client = _FakeClient({
      'status': true,
      'TOP_K': 3,
      'web': {
        'ENABLE_WEB_SEARCH': false,
        'WEB_SEARCH_ENGINE': 'searxng',
        'WEB_SEARCH_RESULT_COUNT': 3,
        'SEARXNG_QUERY_URL': 'http://s',
        'BRAVE_SEARCH_API_KEY': 'secret',
        'WEB_SEARCH_DOMAIN_FILTER_LIST': ['a.com'],
      },
    });
    final section = adminConfigSections.firstWhere(
      (s) => s.title == 'Web Search',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: ConfigEditorScreen(section: section),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Enable web search'), findsOneWidget);
    expect(find.text('Searxng query URL'), findsOneWidget);
    // Another engine's key stays out of the way until asked for.
    expect(find.text('Brave search API key'), findsNothing);
    expect(find.text('Top K'), findsNothing);

    await tester.tap(find.text('Enable web search'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Web search result count'),
      '5',
    );
    await tester.enterText(
      find.widgetWithText(
        TextFormField,
        'Web search domain filter list (comma separated)',
      ),
      'a.com, b.org',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final body = client.saved.single as Map;
    expect(body.containsKey('status'), isFalse);
    expect(body['TOP_K'], 3);
    final web = body['web'] as Map;
    expect(web['ENABLE_WEB_SEARCH'], isTrue);
    expect(web['WEB_SEARCH_RESULT_COUNT'], 5);
    expect(web['WEB_SEARCH_DOMAIN_FILTER_LIST'], ['a.com', 'b.org']);
    expect(web['BRAVE_SEARCH_API_KEY'], 'secret');

    await tester.tap(find.byTooltip('Show every setting'));
    await tester.pumpAndSettle();
    expect(find.text('Brave search API key'), findsOneWidget);
  });

  testWidgets('embedding shows the chosen engine\'s server only', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final client = _FakeClient({
      'RAG_EMBEDDING_ENGINE': 'ollama',
      'RAG_EMBEDDING_MODEL': 'nomic',
      'openai_config': {'url': 'https://o', 'key': ''},
      'ollama_config': {'url': 'http://l', 'key': ''},
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientProvider.overrideWithValue(client)],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: ConfigEditorScreen(
            section: adminConfigSections.firstWhere(
              (s) => s.title == 'Embedding',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ollama config'), findsOneWidget);
    expect(find.text('Openai config'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'URL'),
      'http://m',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      ((client.saved.single as Map)['ollama_config'] as Map)['url'],
      'http://m',
    );
  });
}
