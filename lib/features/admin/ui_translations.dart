/// Admin > UI translations: the server's own wording for any text people
/// see, per language, as the web's Admin > Settings > General > UI >
/// UI translations ("Add translation"). The web and this app both use it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';

/// One row: the text as written, and its wording in each language.
class UiTranslation {
  UiTranslation(this.original, [Map<String, String>? by])
    : byLanguage = by ?? {};
  String original;
  final Map<String, String> byLanguage;
}

/// The server's {language: {original: wording}} as rows.
List<UiTranslation> translationRows(Object? i18n) {
  final rows = <String, UiTranslation>{};
  if (i18n is Map) {
    for (final l in i18n.entries) {
      if (l.value is! Map) continue;
      for (final w in (l.value as Map).entries) {
        rows
                .putIfAbsent('${w.key}', () => UiTranslation('${w.key}'))
                .byLanguage['${l.key}'] =
            '${w.value}';
      }
    }
  }
  return rows.values.toList();
}

/// Rows back to what the server keeps. Throws when a worded row has no
/// original text, or two rows have the same one, as the web refuses.
Map<String, Map<String, String>> translationsFrom(List<UiTranslation> rows) {
  final out = <String, Map<String, String>>{};
  final seen = <String>{};
  for (final r in rows) {
    final worded = {
      for (final e in r.byLanguage.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value,
    };
    final original = r.original.trim();
    if (original.isEmpty) {
      if (worded.isNotEmpty) {
        throw const FormatException('Original text is required');
      }
      continue;
    }
    if (!seen.add(original)) {
      throw FormatException('Duplicate original text: $original');
    }
    for (final e in worded.entries) {
      (out[e.key] ??= {})[original] = e.value;
    }
  }
  return out;
}

class UiTranslationsScreen extends ConsumerStatefulWidget {
  const UiTranslationsScreen({super.key});

  @override
  ConsumerState<UiTranslationsScreen> createState() =>
      _UiTranslationsScreenState();
}

class _UiTranslationsScreenState extends ConsumerState<UiTranslationsScreen> {
  static const _path = '/api/v1/auths/admin/config';
  Map<String, dynamic>? _config;
  List<UiTranslation> _rows = [];
  List<AppLanguage> _languages = const [];
  String _language = AppStrings.instance.code ?? 'en-US';
  bool _dirty = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    AppStrings.languages().then((all) {
      if (mounted) setState(() => _languages = all);
    });
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await ref.read(clientProvider).send('GET', _path);
      if (!mounted) return;
      setState(() {
        _config = (c as Map).cast<String, dynamic>();
        _rows = translationRows(_config!['I18N']);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save() async {
    final Map<String, Map<String, String>> i18n;
    try {
      i18n = translationsFrom(_rows);
    } on FormatException catch (e) {
      return _say(tr(e.message));
    }
    setState(() => _saving = true);
    try {
      final res = await ref
          .read(clientProvider)
          .send('POST', _path, body: {..._config!, 'I18N': i18n});
      if (res is Map) _config = res.cast<String, dynamic>();
      ref.invalidate(serverConfigProvider);
      if (mounted) {
        setState(() => _dirty = false);
        _say(tr('Saved'));
      }
    } catch (e) {
      if (mounted) _say('${tr('Not saved')}: $e');
    }
    if (mounted) setState(() => _saving = false);
  }

  void _changed() {
    if (!_dirty) setState(() => _dirty = true);
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const T('UI translations'),
        actions: [
          TextButton(
            onPressed: _dirty && !_saving ? _save : null,
            child: const T('Save'),
          ),
        ],
      ),
      floatingActionButton: _config == null
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const T('Add translation'),
              onPressed: () => setState(() {
                if (_rows.isEmpty || _rows.last.original.trim().isNotEmpty) {
                  _rows.add(UiTranslation(''));
                }
              }),
            ),
      body: _config == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!),
                    ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: [
                T(
                  'Your own wording for any text people see, in each '
                  'language: the web and this app show it instead.',
                  style: TextStyle(color: muted),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _language,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: tr('Language')),
                  items: [
                    for (final l
                        in _languages.isEmpty
                            ? [(code: _language, title: _language)]
                            : _languages)
                      DropdownMenuItem(value: l.code, child: Text(l.title)),
                  ],
                  onChanged: (v) => setState(() => _language = v!),
                ),
                const SizedBox(height: 8),
                if (_rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: T(
                      'No translations yet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: muted),
                    ),
                  ),
                for (final r in _rows)
                  Card(
                    key: ObjectKey(r),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              children: [
                                TextFormField(
                                  initialValue: r.original,
                                  decoration: InputDecoration(
                                    labelText: tr('Key'),
                                  ),
                                  onChanged: (v) {
                                    r.original = v;
                                    _changed();
                                  },
                                ),
                                TextFormField(
                                  key: ValueKey(_language),
                                  initialValue: r.byLanguage[_language] ?? '',
                                  decoration: InputDecoration(
                                    labelText: tr('Value'),
                                  ),
                                  onChanged: (v) {
                                    r.byLanguage[_language] = v;
                                    _changed();
                                  },
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: tr('Delete'),
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              // This language's wording; the row goes once
                              // no language has any.
                              setState(() {
                                r.byLanguage.remove(_language);
                                if (r.byLanguage.values.every(
                                  (w) => w.trim().isEmpty,
                                )) {
                                  _rows.remove(r);
                                }
                              });
                              _changed();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
