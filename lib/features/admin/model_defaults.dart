/// Admin > Models > Model Defaults, as the web's: what every model starts
/// with unless it's given its own: abilities, parameters and the prompt
/// suggestions on a new chat.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/advanced_params.dart';
import '../chat/chat_controller.dart' show modelsProvider, serverConfigProvider;
import '../workspace/models_api.dart';
import '../../core/i18n/app_strings.dart';
import '../workspace/models_screen.dart'
    show PromptSuggestionsEditor, modelsApiProvider, readSuggestions;

/// The abilities every model has unless an admin sets others, as the web.
const defaultCapabilities = {
  'file_context': true,
  'vision': true,
  'file_upload': true,
  'web_search': true,
  'image_generation': true,
  'code_interpreter': true,
  'terminal': true,
  'citations': true,
  'status_updates': true,
  'memory': true,
  'builtin_tools': true,
};

/// The saved defaults' abilities, or the web's when none were saved.
Map<String, dynamic> savedCapabilities(Map<String, dynamic> config) {
  final meta = config['DEFAULT_MODEL_METADATA'] as Map?;
  final caps = meta == null || meta.isEmpty ? null : meta['capabilities'];
  return caps is Map ? caps.cast<String, dynamic>() : {...defaultCapabilities};
}

/// The models config with new defaults; other default settings (feature
/// switches, built-in tools) are kept as they were.
Map<String, dynamic> withDefaults(
  Map<String, dynamic> config, {
  required Map<String, dynamic> capabilities,
  required Map<String, dynamic> params,
}) {
  final meta = (config['DEFAULT_MODEL_METADATA'] as Map?) ?? const {};
  return {
    'DEFAULT_MODELS': config['DEFAULT_MODELS'],
    'DEFAULT_PINNED_MODELS': config['DEFAULT_PINNED_MODELS'],
    'MODEL_ORDER_LIST': config['MODEL_ORDER_LIST'] ?? const [],
    'DEFAULT_MODEL_METADATA': {...meta, 'capabilities': capabilities},
    'DEFAULT_MODEL_PARAMS': {
      for (final e in params.entries)
        if (e.value != null && e.value != '') e.key: e.value,
    },
  };
}

class ModelDefaultsScreen extends ConsumerStatefulWidget {
  const ModelDefaultsScreen({super.key});

  @override
  ConsumerState<ModelDefaultsScreen> createState() =>
      _ModelDefaultsScreenState();
}

class _ModelDefaultsScreenState extends ConsumerState<ModelDefaultsScreen> {
  Map<String, dynamic>? _config;
  Map<String, dynamic> _caps = {};
  Map<String, dynamic> _params = {};
  List<Map<String, dynamic>>? _suggestions;
  Object? _i18n;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final config = await ref.read(modelsApiProvider).config();
      final server = await ref.read(clientProvider).config();
      if (!mounted) return;
      setState(() {
        _config = config;
        _caps = {...savedCapabilities(config)};
        _params = {
          ...?(config['DEFAULT_MODEL_PARAMS'] as Map?)?.cast<String, dynamic>(),
        };
        _suggestions = readSuggestions(server['default_prompt_suggestions']);
        _i18n = server['default_prompt_suggestions_i18n'];
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final api = ref.read(modelsApiProvider);
      // Read again, so a change made elsewhere meanwhile isn't undone.
      final fresh = await api.config();
      await api.saveConfig(
        withDefaults(fresh, capabilities: _caps, params: _params),
      );
      await ref
          .read(clientProvider)
          .send(
            'POST',
            '/api/v1/configs/suggestions',
            body: {
              'suggestions': _suggestions == null
                  ? null
                  : [
                      for (final s in _suggestions!)
                        if ('${s['content'] ?? ''}'.trim().isNotEmpty) s,
                    ],
              'i18n': _i18n ?? const {},
            },
          );
      ref
        ..invalidate(serverConfigProvider)
        ..invalidate(modelsProvider);
      messenger.showSnackBar(
        const SnackBar(content: T('Models configuration saved')),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Not saved: $e')));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final labels = {
      'file_context': 'Uses attached files',
      ...modelCapabilities,
    };
    return Scaffold(
      appBar: AppBar(
        title: const T('Model Defaults'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _config == null || _busy ? null : _save,
              child: const T('Save'),
            ),
          ),
        ],
      ),
      body: _config == null
          ? Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text("Couldn't load the defaults.\n$_error"),
                    )
                  : const CircularProgressIndicator(),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                T(
                  "What every model starts with, unless it's given its own "
                  'in its editor.',
                  style: TextStyle(color: muted),
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const T('Capabilities'),
                  subtitle: Text(
                    '${_caps.values.where((v) => v == true).length} on',
                  ),
                  children: [
                    for (final c in labels.entries)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(c.value),
                        value: _caps[c.key] == true,
                        onChanged: (on) =>
                            setState(() => _caps[c.key] = on == true),
                      ),
                  ],
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const T('Model Parameters'),
                  subtitle: Text(
                    _params.isEmpty
                        ? 'All on default'
                        : '${_params.length} set',
                  ),
                  children: [
                    AdvancedParamsEditor(
                      params: _params,
                      onChanged: (k, v) => setState(
                        () => v == null ? _params.remove(k) : _params[k] = v,
                      ),
                    ),
                  ],
                ),
                PromptSuggestionsEditor(
                  value: _suggestions,
                  onChanged: (v) => setState(() => _suggestions = v),
                ),
              ],
            ),
    );
  }
}
