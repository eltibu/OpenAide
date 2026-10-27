/// The Admin Panel's settings pages, native: each reads the server's own
/// settings as they are and shows every one of them, so a setting a newer
/// server adds shows up here without an app update. Switches for on/off,
/// lists for engines, hidden text for keys, a full editor for templates.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';

/// Words written in capitals in a setting's name.
const _acronyms = {
  'API', 'URL', 'RAG', 'PDF', 'OCR', 'TTS', 'STT', 'SSL', 'ID', 'JSON', //
  'LLM', 'BM25', 'VL', 'PSE', 'AI', 'MCP', 'IQ', 'V7', 'SK', 'SID', 'IO',
  'HTTP', 'HTTPS', 'WS', 'TOP', 'K', 'OAUTH', 'LDAP', 'JWT', 'CSV',
};

/// "ENABLE_RAG_HYBRID_SEARCH" as "Enable RAG hybrid search".
String settingLabel(String key) {
  final words = key.split('_').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return key;
  final out = <String>[];
  for (final (i, w) in words.indexed) {
    final up = w.toUpperCase();
    if (_acronyms.contains(up) && up != 'TOP' && up != 'K') {
      out.add(up);
    } else if (up == 'K' && i > 0 && words[i - 1].toUpperCase() == 'TOP') {
      out.add('K');
    } else if (i == 0) {
      out.add('${w[0].toUpperCase()}${w.substring(1).toLowerCase()}');
    } else {
      out.add(w.toLowerCase());
    }
  }
  return out.join(' ');
}

/// Keys, tokens and passwords, shown hidden.
bool isSecretSetting(String key) {
  final k = key.toUpperCase();
  return k.endsWith('_KEY') ||
      k.endsWith('API_KEY') ||
      k.contains('TOKEN') &&
          !k.contains('TOKENS') &&
          !k.contains('TOKENIZER') ||
      k.contains('PASSWORD') ||
      k.contains('SECRET') ||
      k.endsWith('_SK') ||
      k == 'KEY' ||
      k.endsWith('_API_AUTH') ||
      k.endsWith('_AUTH') && !k.contains('TYPE');
}

/// Long text: prompt templates and workflows.
bool isLongSetting(String key, Object? value) =>
    key.contains('TEMPLATE') ||
    key.contains('PROMPT') ||
    key.contains('WORKFLOW') && !key.contains('NODES') ||
    value is String && value.contains('\n');

/// The settings to hide because they belong to an engine not chosen:
/// for each engine key, its choices and the name prefixes of their own
/// settings.
typedef EngineSettings = Map<String, Map<String, List<String>>>;

bool hiddenByEngine(String key, Map data, EngineSettings engines) {
  for (final MapEntry(key: engineKey, value: choices) in engines.entries) {
    if (!data.containsKey(engineKey)) continue;
    final chosen = '${data[engineKey] ?? ''}';
    for (final MapEntry(key: choice, value: prefixes) in choices.entries) {
      if (choice == chosen) continue;
      // A setting shared with the chosen engine stays.
      final shared = (choices[chosen] ?? const []).any(key.startsWith);
      if (!shared && prefixes.any(key.startsWith)) return true;
    }
  }
  return false;
}

/// One of the Admin Panel's settings pages.
class ConfigSection {
  const ConfigSection({
    required this.title,
    required this.read,
    required this.save,
    this.path = const [],
    this.exclude = const {},
    this.choices = const {},
    this.engines = const {},
    this.help,
  });

  final String title;

  /// Where the server's settings are read and saved.
  final String read;
  final String save;

  /// Shows only the part of the settings under these keys.
  final List<String> path;
  final Set<String> exclude;

  /// Known choices for a setting (the current value is always offered).
  final Map<String, List<String>> choices;
  final EngineSettings engines;
  final String? help;
}

const _webEngines = <String, List<String>>{
  '': [],
  'searxng': ['SEARXNG_'],
  'yacy': ['YACY_'],
  'google_pse': ['GOOGLE_PSE_'],
  'brave': ['BRAVE_SEARCH_'],
  'brave_llm_context': ['BRAVE_SEARCH_'],
  'kagi': ['KAGI_'],
  'mojeek': ['MOJEEK_'],
  'bocha': ['BOCHA_'],
  'serpstack': ['SERPSTACK_'],
  'serper': ['SERPER_'],
  'serphouse': ['SERPHOUSE_'],
  'serply': ['SERPLY_'],
  'searchapi': ['SEARCHAPI_'],
  'serpapi': ['SERPAPI_'],
  'duckduckgo': ['DDGS_'],
  'tavily': ['TAVILY_API_KEY'],
  'jina': ['JINA_'],
  'bing': ['BING_'],
  'exa': ['EXA_'],
  'perplexity': [
    'PERPLEXITY_API_KEY',
    'PERPLEXITY_MODEL',
    'PERPLEXITY_SEARCH_CONTEXT',
  ],
  'perplexity_search': ['PERPLEXITY_API_KEY', 'PERPLEXITY_SEARCH_API_URL'],
  'sougou': ['SOUGOU_'],
  'firecrawl': ['FIRECRAWL_'],
  'external': ['EXTERNAL_WEB_SEARCH_'],
  'yandex': ['YANDEX_'],
  'youcom': ['YOUCOM_'],
  'linkup': ['LINKUP_'],
  'ollama_cloud': ['OLLAMA_CLOUD_'],
  'openserp': ['OPENSERP_'],
  'staan': ['STAAN_'],
  'microsoft_web_iq': ['MICROSOFT_WEB_IQ_'],
  'azure': ['AZURE_'],
};

const _extractionEngines = <String, List<String>>{
  '': [],
  'external': ['EXTERNAL_DOCUMENT_LOADER_'],
  'tika': ['TIKA_'],
  'docling': ['DOCLING_'],
  'document_intelligence': ['DOCUMENT_INTELLIGENCE_'],
  'mistral_ocr': ['MISTRAL_OCR_'],
  'datalab_marker': ['DATALAB_MARKER_'],
  'mineru': ['MINERU_'],
  'paddleocr_vl': ['PADDLEOCR_VL_'],
};

/// The Admin Panel pages built from the server's own settings.
final adminConfigSections = <ConfigSection>[
  const ConfigSection(
    title: 'Documents',
    read: '/api/v1/retrieval/config',
    save: '/api/v1/retrieval/config/update',
    exclude: {'web', 'status'},
    choices: {
      'PDF_LOADER_MODE': ['page', 'single'],
      'TEXT_SPLITTER': ['', 'character', 'token'],
      'RAG_RERANKING_ENGINE': ['', 'external'],
      'MINERU_API_MODE': ['local', 'cloud'],
      'DATALAB_MARKER_OUTPUT_FORMAT': ['markdown', 'json', 'html'],
    },
    engines: {
      'CONTENT_EXTRACTION_ENGINE': _extractionEngines,
      'RAG_RERANKING_ENGINE': {
        '': [],
        'external': ['RAG_EXTERNAL_RERANKER_'],
      },
    },
    help: 'How files are read, split and searched.',
  ),
  const ConfigSection(
    title: 'Web Search',
    read: '/api/v1/retrieval/config',
    save: '/api/v1/retrieval/config/update',
    path: ['web'],
    choices: {
      'WEB_LOADER_ENGINE': [
        '',
        'safe_web',
        'playwright',
        'firecrawl',
        'tavily',
        'external',
      ],
      'TAVILY_EXTRACT_DEPTH': ['basic', 'advanced'],
      'TAVILY_SEARCH_DEPTH': ['basic', 'advanced'],
      'PERPLEXITY_SEARCH_CONTEXT_USAGE': ['low', 'medium', 'high'],
    },
    engines: {
      'WEB_SEARCH_ENGINE': _webEngines,
      'WEB_LOADER_ENGINE': {
        '': [],
        'safe_web': [],
        'playwright': ['PLAYWRIGHT_'],
        'firecrawl': ['FIRECRAWL_'],
        'tavily': ['TAVILY_EXTRACT_'],
        'external': ['EXTERNAL_WEB_LOADER_'],
      },
    },
    help: 'Which search engine models use, and how pages are read.',
  ),
  const ConfigSection(
    title: 'Audio',
    read: '/api/v1/audio/config',
    save: '/api/v1/audio/config/update',
    choices: {
      'ENGINE': [
        '',
        'openai',
        'elevenlabs',
        'azure',
        'transformers',
        'deepgram',
        'mistral',
      ],
      'SPLIT_ON': ['punctuation', 'paragraphs', 'none'],
      'PROVIDER': ['openai', 'azure'],
      'AUTH_TYPE': ['api_key', 'bearer'],
    },
    help: 'Speech to text, text to speech and live voice.',
  ),
  const ConfigSection(
    title: 'Images',
    read: '/api/v1/images/config',
    save: '/api/v1/images/config/update',
    choices: {},
    engines: {
      'IMAGE_GENERATION_ENGINE': {
        'openai': ['IMAGES_OPENAI_'],
        'automatic1111': ['AUTOMATIC1111_'],
        'comfyui': ['COMFYUI_'],
        'gemini': ['IMAGES_GEMINI_'],
      },
      'IMAGE_EDIT_ENGINE': {
        'openai': ['IMAGES_EDIT_OPENAI_'],
        'comfyui': ['IMAGES_EDIT_COMFYUI_'],
        'gemini': ['IMAGES_EDIT_GEMINI_'],
      },
    },
    help: 'Making and changing pictures.',
  ),
  const ConfigSection(
    title: 'Code Execution',
    read: '/api/v1/configs/code_execution',
    save: '/api/v1/configs/code_execution',
    choices: {
      'CODE_EXECUTION_ENGINE': ['pyodide', 'jupyter'],
      'CODE_INTERPRETER_ENGINE': ['pyodide', 'jupyter'],
      'CODE_EXECUTION_JUPYTER_AUTH': ['', 'token', 'password'],
      'CODE_INTERPRETER_JUPYTER_AUTH': ['', 'token', 'password'],
    },
    help: 'Running code from replies, and the code interpreter.',
  ),
  const ConfigSection(
    title: 'Interface and tasks',
    read: '/api/v1/tasks/config',
    save: '/api/v1/tasks/config/update',
    help: 'Titles, tags, follow-ups, autocomplete and their prompts.',
  ),
  const ConfigSection(
    title: 'Connections',
    read: '/api/v1/configs/connections',
    save: '/api/v1/configs/connections',
    help: 'Direct connections and the model list cache.',
  ),
  const ConfigSection(
    title: 'Evaluations',
    read: '/api/v1/evaluations/config',
    save: '/api/v1/evaluations/config',
    help: 'Arena models for blind comparisons.',
  ),
];

Object? _deepCopy(Object? v) => v == null ? null : jsonDecode(jsonEncode(v));

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// A settings page for one [ConfigSection].
class ConfigEditorScreen extends ConsumerStatefulWidget {
  const ConfigEditorScreen({super.key, required this.section});
  final ConfigSection section;

  @override
  ConsumerState<ConfigEditorScreen> createState() => _ConfigEditorScreenState();
}

class _ConfigEditorScreenState extends ConsumerState<ConfigEditorScreen> {
  Map<String, dynamic>? _all;
  Object? _error;
  bool _dirty = false;
  bool _saving = false;
  bool _showAll = false;
  String _query = '';

  /// Bumped on load so fields start again from the server's values.
  int _generation = 0;

  ConfigSection get _s => widget.section;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(clientProvider).send('GET', _s.read);
      _all = (_deepCopy(res) as Map).cast<String, dynamic>();
      _error = null;
      _dirty = false;
      _generation++;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  /// The part of the settings this page shows.
  Map<String, dynamic> get _data {
    Map<String, dynamic> m = _all!;
    for (final k in _s.path) {
      m = (m[k] as Map).cast<String, dynamic>();
    }
    return m;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final body = Map<String, dynamic>.of(_all!)..remove('status');
      await ref.read(clientProvider).send('POST', _s.save, body: body);
      if (mounted) _say(context, 'Saved');
      await _load();
    } catch (e) {
      if (mounted) _say(context, 'Not saved: $e');
    }
    if (mounted) setState(() => _saving = false);
  }

  void _set(Map<String, dynamic> m, String key, Object? value) {
    m[key] = value;
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<bool> _leave() async {
    if (!_dirty) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Leave without saving?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    return leave == true;
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (popped, _) async {
        if (popped) return;
        final nav = Navigator.of(context);
        if (await _leave()) nav.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_s.title),
          actions: [
            if (_all != null)
              IconButton(
                tooltip: _showAll
                    ? 'Hide other engines\' settings'
                    : 'Show every setting',
                onPressed: () => setState(() => _showAll = !_showAll),
                icon: Icon(
                  _showAll ? Icons.filter_alt_off_outlined : Icons.tune,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: _dirty && !_saving ? _save : null,
                child: Text(_saving ? 'Saving…' : 'Save'),
              ),
            ),
          ],
        ),
        body: _error != null && _all == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Couldn\'t load these settings.\n$_error'),
                ),
              )
            : _all == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                key: ValueKey(_generation),
                padding: const EdgeInsets.only(bottom: 40),
                children: [
                  if (_s.help != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Text(_s.help!, style: TextStyle(color: muted)),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'Find a setting',
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) =>
                          setState(() => _query = v.trim().toLowerCase()),
                    ),
                  ),
                  ..._fields(_data, const []),
                ],
              ),
      ),
    );
  }

  bool _matches(String key) =>
      _query.isEmpty ||
      key.toLowerCase().contains(_query) ||
      settingLabel(key).toLowerCase().contains(_query);

  List<Widget> _fields(Map<String, dynamic> m, List<String> at) {
    final out = <Widget>[];
    final nested = <String>[];
    for (final key in m.keys) {
      if (at.isEmpty && _s.exclude.contains(key)) continue;
      if (key == 'status') continue;
      final v = m[key];
      // Maps of settings (not free-form parameters) become their own group.
      if (v is Map && v.values.any((x) => x is! Map) && _looksLikeSettings(v)) {
        nested.add(key);
        continue;
      }
      if (!_showAll && hiddenByEngine(key, m, _s.engines)) continue;
      if (!_matches(key)) continue;
      out.add(_field(m, key));
    }
    for (final key in nested) {
      final inner = _fields((m[key] as Map).cast<String, dynamic>(), [
        ...at,
        key,
      ]);
      if (inner.isEmpty) continue;
      out
        ..add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text(
              _groupName(key),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        )
        ..addAll(inner);
    }
    return out;
  }

  /// Groups of settings have names in capitals; parameters don't.
  static bool _looksLikeSettings(Map v) =>
      v.isNotEmpty && v.keys.every((k) => '$k' == '$k'.toUpperCase());

  static String _groupName(String key) => switch (key) {
    'tts' => 'Text to speech',
    'stt' => 'Speech to text',
    'realtime' => 'Live voice',
    _ => settingLabel(key),
  };

  Widget _field(Map<String, dynamic> m, String key) {
    final v = m[key];
    final label = settingLabel(key);
    final known = _s.choices[key] ?? _s.engines[key]?.keys.toList();
    if (v is bool) {
      return SwitchListTile(
        title: Text(label),
        value: v,
        onChanged: (on) => setState(() => _set(m, key, on)),
      );
    }
    if (known != null && (v == null || v is String)) {
      final options = [...known, if (!known.contains(v ?? '')) '${v ?? ''}'];
      return ListTile(
        title: Text(label),
        trailing: DropdownButton<String>(
          value: '${v ?? ''}',
          items: [
            for (final o in options)
              DropdownMenuItem(
                value: o,
                child: Text(o.isEmpty ? 'Default' : o),
              ),
          ],
          onChanged: (o) => setState(() => _set(m, key, o)),
        ),
      );
    }
    if (v is Map || (v is List && v.any((x) => x is Map))) {
      return ListTile(
        title: Text(label),
        subtitle: Text(
          v is Map
              ? (v.isEmpty ? 'None' : '${v.length} entries')
              : '${(v as List).length} items',
        ),
        trailing: const Icon(Icons.data_object),
        onTap: () => _editJson(m, key),
      );
    }
    if (isLongSetting(key, v)) {
      final text = '${v ?? ''}';
      return ListTile(
        title: Text(label),
        subtitle: Text(
          text.isEmpty ? 'Default' : text.split('\n').first,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.edit_note),
        onTap: () => _editLong(m, key),
      );
    }
    final list = v is List;
    final number = v is num;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: _TextSetting(
        label: list ? '$label (comma separated)' : label,
        initial: list
            ? v.join(', ')
            : v == null
            ? ''
            : '$v',
        secret: isSecretSetting(key),
        number: number,
        onChanged: (t) {
          final s = t.trim();
          _set(
            m,
            key,
            list
                ? [
                    for (final x in s.split(','))
                      if (x.trim().isNotEmpty) x.trim(),
                  ]
                : v is int
                ? int.tryParse(s) ?? (s.isEmpty ? null : v)
                : v is double
                ? double.tryParse(s) ?? (s.isEmpty ? null : v)
                : v == null
                ? (s.isEmpty
                      ? null
                      : int.tryParse(s) ?? double.tryParse(s) ?? t)
                : t,
          );
        },
      ),
    );
  }

  Future<void> _editLong(Map<String, dynamic> m, String key) async {
    final c = TextEditingController(text: '${m[key] ?? ''}');
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (page) => Scaffold(
          appBar: AppBar(
            title: Text(settingLabel(key)),
            actions: [
              TextButton(
                onPressed: () {
                  c.clear();
                },
                child: const Text('Default'),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton(
                  onPressed: () => Navigator.pop(page, true),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: c,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'Empty uses the server\'s default',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ),
      ),
    );
    if (saved == true) setState(() => _set(m, key, c.text));
    c.dispose();
  }

  Future<void> _editJson(Map<String, dynamic> m, String key) async {
    final c = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(m[key]),
    );
    String? problem;
    final saved = await showDialog<Object?>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: Text(settingLabel(key)),
          content: SizedBox(
            width: 500,
            child: TextField(
              controller: c,
              maxLines: 14,
              minLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                errorText: problem,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  Navigator.pop(d, [jsonDecode(c.text)]);
                } on FormatException catch (e) {
                  set(() => problem = 'Not valid JSON: ${e.message}');
                }
              },
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (saved is List) setState(() => _set(m, key, saved.first));
    c.dispose();
  }
}

class _TextSetting extends StatefulWidget {
  const _TextSetting({
    required this.label,
    required this.initial,
    required this.secret,
    required this.number,
    required this.onChanged,
  });
  final String label;
  final String initial;
  final bool secret;
  final bool number;
  final ValueChanged<String> onChanged;

  @override
  State<_TextSetting> createState() => _TextSettingState();
}

class _TextSettingState extends State<_TextSetting> {
  late bool _hidden = widget.secret;

  @override
  Widget build(BuildContext context) => TextFormField(
    initialValue: widget.initial,
    obscureText: _hidden,
    keyboardType: widget.number
        ? const TextInputType.numberWithOptions(decimal: true, signed: true)
        : TextInputType.text,
    decoration: InputDecoration(
      labelText: widget.label,
      suffixIcon: widget.secret
          ? IconButton(
              tooltip: _hidden ? 'Show' : 'Hide',
              onPressed: () => setState(() => _hidden = !_hidden),
              icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
            )
          : null,
    ),
    onChanged: widget.onChanged,
  );
}
