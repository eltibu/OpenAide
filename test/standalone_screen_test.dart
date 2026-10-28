import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/ai/ai_providers.dart';
import 'package:nexus_assistant/core/models/model_info.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/providers/ai_keys.dart';
import 'package:nexus_assistant/features/standalone/local_chats.dart';
import 'package:nexus_assistant/features/standalone/standalone_screen.dart';

class _Keys extends AiKeys {
  _Keys(this.keys);
  final Map<AiProvider, String> keys;
  @override
  Future<Map<AiProvider, String>> build() async => keys;
}

Widget _app(Map<AiProvider, String> keys, List<ModelInfo> models) =>
    ProviderScope(
      overrides: [
        aiKeysProvider.overrideWith(() => _Keys(keys)),
        providerModelsProvider.overrideWith((ref) async => models),
        localChatsProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
        theme: nexusTheme(Brightness.light),
        home: const StandaloneScreen(),
      ),
    );

void main() {
  testWidgets('a new user is asked to sign in to a provider', (tester) async {
    await tester.pumpWidget(_app(const {}, const []));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to an AI provider'), findsOneWidget);
    expect(find.text('Sign in with OpenRouter'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
  });

  testWidgets('with a key, the chat opens on the best model', (tester) async {
    final models = [
      ModelInfo.fromJson({
        'id': 'direct:anthropic:claude-haiku-5-5',
        'name': 'Claude Haiku 5.5',
        'nexus_provider': 'anthropic',
      }),
      ModelInfo.fromJson({
        'id': 'direct:anthropic:claude-sonnet-5-5',
        'name': 'Claude Sonnet 5.5',
        'nexus_provider': 'anthropic',
      }),
    ];
    await tester.pumpWidget(
      _app(const {AiProvider.anthropic: 'sk-ant'}, models),
    );
    await tester.pumpAndSettle();
    expect(find.text('How can I help?'), findsOneWidget);
    expect(find.text('Claude Sonnet 5.5'), findsOneWidget);
    await tester.tap(find.text('Claude Sonnet 5.5'));
    await tester.pumpAndSettle();
    expect(find.text('Claude Haiku 5.5'), findsOneWidget);
  });
}
