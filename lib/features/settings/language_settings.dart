/// Settings > General > Language: the app in another language, as on the
/// web. Phrases the web translates come with the app; the rest are
/// translated once by a model on your server, then kept on the phone.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';
import '../chat/chat_controller.dart';

/// The name of the chosen language, for the settings row.
Future<String> languageName(String? choice) async {
  if (choice == null) return 'English (US)';
  if (choice == 'system') return tr('Same as the phone');
  for (final l in await AppStrings.languages()) {
    if (l.code == choice) return l.title;
  }
  return choice;
}

/// Pulls a {"phrase": "translation"} object out of a model's reply, even
/// when it wraps it in a code block or adds words around it.
Map<String, String> parseTranslations(String reply, List<String> asked) {
  final start = reply.indexOf('{');
  final end = reply.lastIndexOf('}');
  if (start < 0 || end <= start) return {};
  try {
    final map = jsonDecode(reply.substring(start, end + 1));
    if (map is! Map) return {};
    final wanted = asked.toSet();
    return {
      for (final e in map.entries)
        if (wanted.contains(e.key) &&
            e.value is String &&
            (e.value as String).trim().isNotEmpty)
          '${e.key}': e.value as String,
    };
  } catch (_) {
    return {};
  }
}

/// Asks [model] on the server to translate [phrases] into [language].
Future<Map<String, String>> translateWithServer(
  OpenWebUiClient client,
  String model,
  String language,
  List<String> phrases,
) async {
  final res = await client.send(
    'POST',
    '/api/chat/completions',
    body: {
      'model': model,
      'stream': false,
      'messages': [
        {
          'role': 'system',
          'content':
              'You translate the words of a phone app\'s screens. Reply with '
              'only a JSON object that maps each English phrase, exactly as '
              'given, to its translation in $language. Keep placeholders '
              'like {{name}}, line breaks, punctuation and the same tone. '
              'Do not translate the names OpenAide, Open WebUI or Android.',
        },
        {'role': 'user', 'content': jsonEncode(phrases)},
      ],
    },
  );
  final choices = res is Map ? res['choices'] : null;
  final text = choices is List && choices.isNotEmpty
      ? '${(choices.first as Map)['message']?['content'] ?? ''}'
      : '';
  return parseTranslations(text, phrases);
}

class LanguageSettings extends ConsumerStatefulWidget {
  const LanguageSettings({super.key});

  @override
  ConsumerState<LanguageSettings> createState() => _LanguageSettingsState();
}

class _LanguageSettingsState extends ConsumerState<LanguageSettings> {
  final _strings = AppStrings.instance;
  List<AppLanguage> _all = const [];
  int _missing = 0;
  (int, int)? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    AppStrings.languages().then((all) {
      if (mounted) setState(() => _all = all);
    });
    _count();
  }

  Future<void> _count() async {
    final c = _strings.code;
    final n = c == null || c.startsWith('en-')
        ? 0
        : (await _strings.missing(c)).length;
    if (mounted) setState(() => _missing = n);
  }

  Future<void> _choose(String? choice) async {
    await _strings.choose(choice);
    setState(() => _error = null);
    await _count();
  }

  Future<void> _translate() async {
    final c = _strings.code;
    if (c == null) return;
    final title = _all
        .firstWhere((l) => l.code == c, orElse: () => (code: c, title: c))
        .title;
    final client = ref.read(clientProvider);
    final model = await ref.read(defaultModelProvider.future);
    if (model == null) {
      setState(() => _error = tr('Choose a default model first'));
      return;
    }
    final todo = await _strings.missing(c);
    var done = 0;
    setState(() {
      _progress = (0, todo.length);
      _error = null;
    });
    try {
      for (var i = 0; i < todo.length; i += 60) {
        final batch = todo.sublist(i, (i + 60).clamp(0, todo.length));
        final got = await translateWithServer(client, model, title, batch);
        await _strings.addServerWords(c, got);
        done += batch.length;
        if (!mounted) return;
        setState(() => _progress = (done, todo.length));
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (!mounted) return;
    setState(() => _progress = null);
    await _count();
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final progress = _progress;
    // English is the app's own, saved as no choice.
    Widget option(String choice, String title) =>
        RadioListTile<String>(value: choice, title: Text(title));
    return Scaffold(
      appBar: AppBar(title: const T('Language')),
      body: ListView(
        children: [
          if (_missing > 0 || progress != null || _error != null)
            Card(
              margin: const EdgeInsets.all(12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (progress != null) ...[
                      Text(
                        '${tr('Translating')} ${progress.$1} / ${progress.$2}',
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: progress.$2 == 0
                            ? null
                            : progress.$1 / progress.$2,
                      ),
                    ] else if (_missing > 0) ...[
                      Text('$_missing ${tr('phrases are still in English.')}'),
                      const SizedBox(height: 4),
                      T(
                        'Your server\'s default model can translate them '
                        'once; they\'re kept on this phone.',
                        style: TextStyle(color: muted),
                      ),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: _translate,
                        child: const T('Translate them'),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          RadioGroup<String>(
            groupValue: _strings.choice ?? 'en-US',
            onChanged: (v) => _choose(v == 'en-US' ? null : v),
            child: Column(
              children: [
                option('en-US', 'English (US)'),
                option('system', tr('Same as the phone')),
                for (final l in _all)
                  if (l.code != 'en-US') option(l.code, l.title),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
