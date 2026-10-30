/// A model's Provider details, as the web's model editor shows admins
/// (0.12.5): input and output types, context window, maximum output and
/// supported parameters, as the provider reports them in /api/models.
library;

import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/theme.dart';

typedef ProviderInfo = ({
  List<String>? inputs,
  List<String>? outputs,
  int? context,
  int? providerContext,
  int? maxOutput,
  List<String>? parameters,
});

Map<String, dynamic> _record(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : const {};

List<String>? _strings(Object? v) {
  if (v is! List || v.any((e) => e is! String || e.trim().isEmpty)) {
    return null;
  }
  return {for (final e in v) (e as String).trim()}.toList();
}

int? _limit(Object? v) => v is int && v > 0
    ? v
    : v is double && v > 0 && v == v.roundToDouble()
    ? v.toInt()
    : null;

/// What the provider reports for a /api/models entry; the web reads the
/// `openai` copy when there is one.
ProviderInfo providerInfo(Map<String, dynamic>? entry) {
  final e = _record(entry);
  final source = e['openai'] != null ? _record(e['openai']) : e;
  final arch = _record(source['architecture']);
  final top = _record(source['top_provider']);
  return (
    inputs: _strings(arch['input_modalities']),
    outputs: _strings(arch['output_modalities']),
    context: _limit(source['context_length']),
    providerContext: _limit(top['context_length']),
    maxOutput: _limit(top['max_completion_tokens']),
    parameters: _strings(source['supported_parameters']),
  );
}

bool providerInfoAvailable(ProviderInfo i) =>
    i.inputs != null ||
    i.outputs != null ||
    i.context != null ||
    i.providerContext != null ||
    i.maxOutput != null ||
    i.parameters != null;

const _modalities = {
  'text': 'Text',
  'image': 'Image',
  'audio': 'Audio',
  'video': 'Video',
  'file': 'File',
  'embeddings': 'Embeddings',
};

String _tokens(int? v) {
  if (v == null) return tr('Not provided');
  final s = v.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '$s ${tr('tokens')}';
}

String _list(List<String>? v, {bool modal = false}) => v == null
    ? tr('Not provided')
    : v.isEmpty
    ? tr('None reported')
    : v.map((e) => modal ? tr(_modalities[e] ?? e) : e).join(', ');

class ProviderDetails extends StatelessWidget {
  const ProviderDetails({super.key, required this.entry});

  /// The model's /api/models entry (its base model's, for a custom model).
  final Map<String, dynamic>? entry;

  @override
  Widget build(BuildContext context) {
    final i = providerInfo(entry);
    final muted = context.nexus.muted;
    if (!providerInfoAvailable(i)) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: const T('Provider details'),
        subtitle: T('Not provided', style: TextStyle(color: muted)),
      );
    }
    final rows = <(String, String)>[
      ('Inputs', _list(i.inputs, modal: true)),
      ('Outputs', _list(i.outputs, modal: true)),
      ('Context window', _tokens(i.context)),
      if (i.providerContext != null && i.providerContext != i.context)
        ('Provider context', _tokens(i.providerContext)),
      if (i.maxOutput != null) ('Max output', _tokens(i.maxOutput)),
      ('Supported parameters', _list(i.parameters)),
    ];
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const T('Provider details'),
      subtitle: Text(
        i.context == null
            ? tr('Reported by the provider.')
            : '${tr('Reported by the provider.')} ${_tokens(i.context)}',
        style: TextStyle(color: muted),
      ),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 130,
                  child: T(label, style: TextStyle(color: muted)),
                ),
                Expanded(child: SelectableText(value)),
              ],
            ),
          ),
      ],
    );
  }
}
