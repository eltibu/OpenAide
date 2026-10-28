/// Every model setting the web's Advanced Parameters offer, as one editor
/// used for a chat's Controls, Settings > General and a model's own
/// defaults. Left on Default, a setting isn't sent and the next level's
/// value (or the model's) applies.
library;

import 'package:flutter/material.dart';

enum ParamKind { slider, integer, toggle, choice, text, list, tags }

class ParamSpec {
  const ParamSpec(
    this.key,
    this.label,
    this.help,
    this.kind, {
    this.min = 0,
    this.max = 1,
    this.start = 0,
    this.step = 0.05,
    this.options = const {},
    this.other = false,
    this.hint,
    this.ollama = false,
  });

  final String key;
  final String label;
  final String help;
  final ParamKind kind;

  /// Sliders: range, the value they start at when switched on, and step.
  final double min, max, start, step;

  /// Choices: value to label.
  final Map<Object, String> options;

  /// Choices: also offer a typed value.
  final bool other;
  final String? hint;

  /// Only Ollama models use it.
  final bool ollama;
}

const advancedParams = <ParamSpec>[
  ParamSpec(
    'stream_response',
    'Stream response',
    'Show the reply as it is written.',
    ParamKind.toggle,
  ),
  ParamSpec(
    'stream_delta_chunk_size',
    'Stream delta chunk size',
    'Words sent together while streaming; higher is lighter on the phone.',
    ParamKind.integer,
  ),
  ParamSpec(
    'compact_token_threshold',
    'Compact token threshold',
    'Summarise older messages once a chat is this long.',
    ParamKind.integer,
  ),
  ParamSpec(
    'function_calling',
    'Function calling',
    'Native lets the model call tools itself.',
    ParamKind.choice,
    options: {'native': 'Native'},
  ),
  ParamSpec(
    'reasoning_tags',
    'Reasoning tags',
    'How thinking is found in replies.',
    ParamKind.tags,
  ),
  ParamSpec(
    'seed',
    'Seed',
    'The same seed repeats an answer.',
    ParamKind.integer,
  ),
  ParamSpec(
    'stop',
    'Stop',
    'The reply ends when one of these is written.',
    ParamKind.list,
    hint: 'Comma-separated, like \\n\\n, END',
  ),
  ParamSpec(
    'temperature',
    'Temperature',
    'Higher is more creative, lower more focused.',
    ParamKind.slider,
    max: 2,
    start: 0.8,
  ),
  ParamSpec(
    'reasoning_effort',
    'Reasoning effort',
    'How hard a reasoning model thinks.',
    ParamKind.choice,
    options: {'low': 'Low', 'medium': 'Medium', 'high': 'High'},
    other: true,
  ),
  ParamSpec(
    'logit_bias',
    'Logit bias',
    'Make tokens likelier or less likely.',
    ParamKind.text,
    hint: 'token:bias pairs, like 5432:100, 413:-100',
  ),
  ParamSpec(
    'max_tokens',
    'Max tokens',
    'Longest reply allowed.',
    ParamKind.integer,
  ),
  ParamSpec(
    'top_k',
    'Top K',
    'Picks from this many likeliest words.',
    ParamKind.integer,
  ),
  ParamSpec(
    'top_p',
    'Top P',
    'Lower keeps to the likeliest words.',
    ParamKind.slider,
    start: 0.9,
  ),
  ParamSpec(
    'min_p',
    'Min P',
    'Drops words much less likely than the best.',
    ParamKind.slider,
  ),
  ParamSpec(
    'frequency_penalty',
    'Frequency penalty',
    'Discourages repeating words.',
    ParamKind.slider,
    min: -2,
    max: 2,
  ),
  ParamSpec(
    'presence_penalty',
    'Presence penalty',
    'Encourages new topics.',
    ParamKind.slider,
    min: -2,
    max: 2,
  ),
  ParamSpec(
    'mirostat',
    'Mirostat',
    'Keeps surprise steady while writing.',
    ParamKind.choice,
    options: {0: 'Off', 1: 'Mirostat', 2: 'Mirostat 2.0'},
    ollama: true,
  ),
  ParamSpec(
    'mirostat_eta',
    'Mirostat eta',
    'How fast Mirostat adapts.',
    ParamKind.slider,
    start: 0.1,
    ollama: true,
  ),
  ParamSpec(
    'mirostat_tau',
    'Mirostat tau',
    'Lower is more focused and coherent.',
    ParamKind.slider,
    max: 10,
    start: 5,
    step: 0.5,
    ollama: true,
  ),
  ParamSpec(
    'repeat_last_n',
    'Repeat last n',
    'How far back to look for repeats (-1 is all).',
    ParamKind.integer,
    ollama: true,
  ),
  ParamSpec(
    'tfs_z',
    'Tfs z',
    'Tail-free sampling; 1 is off.',
    ParamKind.slider,
    max: 2,
    start: 1,
    ollama: true,
  ),
  ParamSpec(
    'repeat_penalty',
    'Repeat penalty',
    'Higher punishes repeats more.',
    ParamKind.slider,
    max: 2,
    start: 1.1,
    ollama: true,
  ),
  ParamSpec(
    'use_mmap',
    'Use mmap',
    'Map the model file instead of loading it all.',
    ParamKind.toggle,
    ollama: true,
  ),
  ParamSpec(
    'use_mlock',
    'Use mlock',
    'Keep the model in memory.',
    ParamKind.toggle,
    ollama: true,
  ),
  ParamSpec(
    'think',
    'Think',
    'Let a thinking model think first.',
    ParamKind.toggle,
    ollama: true,
  ),
  ParamSpec(
    'format',
    'Format',
    'Ask for JSON or another format.',
    ParamKind.choice,
    options: {'json': 'JSON'},
    other: true,
    ollama: true,
  ),
  ParamSpec(
    'keep_alive',
    'Keep alive',
    'How long the model stays loaded after a reply.',
    ParamKind.text,
    hint: 'Like 5m, 1h or -1',
    ollama: true,
  ),
  ParamSpec(
    'num_keep',
    'Num keep',
    'Tokens kept when the context fills up.',
    ParamKind.integer,
    ollama: true,
  ),
  ParamSpec(
    'num_ctx',
    'Num ctx',
    'How much of the chat the model sees (context length).',
    ParamKind.integer,
    ollama: true,
  ),
  ParamSpec(
    'num_batch',
    'Num batch',
    'Tokens read at once.',
    ParamKind.integer,
    ollama: true,
  ),
  ParamSpec(
    'num_thread',
    'Num thread',
    'CPU threads to use.',
    ParamKind.integer,
    ollama: true,
  ),
  ParamSpec(
    'num_gpu',
    'Num gpu',
    'Layers put on the GPU.',
    ParamKind.integer,
    ollama: true,
  ),
];

/// Stop words as the web stores them: a list, from a comma-separated line.
List<String>? stopWords(String text) {
  final words = [
    for (final w in text.split(','))
      if (w.trim().isNotEmpty) w.trim(),
  ];
  return words.isEmpty ? null : words;
}

/// The editor. [onChanged] gets null to put a setting back on Default.
class AdvancedParamsEditor extends StatelessWidget {
  const AdvancedParamsEditor({
    super.key,
    required this.params,
    required this.onChanged,
  });

  final Map<String, dynamic> params;
  final void Function(String key, Object? value) onChanged;

  @override
  Widget build(BuildContext context) {
    final ollamaSet = advancedParams.any(
      (p) => p.ollama && params[p.key] != null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in advancedParams)
          if (!p.ollama)
            _ParamRow(spec: p, value: params[p.key], onChanged: onChanged),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          initiallyExpanded: ollamaSet,
          title: const Text('Ollama settings'),
          subtitle: const Text('Only models served by Ollama use these'),
          children: [
            for (final p in advancedParams)
              if (p.ollama)
                _ParamRow(spec: p, value: params[p.key], onChanged: onChanged),
          ],
        ),
        _CustomParams(
          value:
              (params['custom_params'] as Map?)?.cast<String, dynamic>() ??
              const {},
          onChanged: (m) => onChanged('custom_params', m.isEmpty ? null : m),
        ),
      ],
    );
  }
}

Future<String?> _ask(
  BuildContext context,
  String title, {
  String initial = '',
  String? hint,
  TextInputType? keyboard,
}) async {
  final text = TextEditingController(text: initial);
  final entered = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: text,
        autofocus: true,
        keyboardType: keyboard,
        decoration: InputDecoration(hintText: hint ?? 'Empty for default'),
        onSubmitted: (x) => Navigator.pop(d, x),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(d, text.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  // Not disposed here: the dialog still shows it while it closes.
  return entered;
}

class _ParamRow extends StatelessWidget {
  const _ParamRow({
    required this.spec,
    required this.value,
    required this.onChanged,
  });

  final ParamSpec spec;
  final Object? value;
  final void Function(String key, Object? value) onChanged;

  static String _fmt(num v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(1) : '$v';

  void _set(Object? v) => onChanged(spec.key, v);

  Widget _chips(
    BuildContext context,
    List<(String, bool, VoidCallback)> chips,
  ) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(spec.label, style: Theme.of(context).textTheme.bodyLarge),
        Text(
          spec.help,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final (label, on, tap) in chips)
              ChoiceChip(
                label: Text(label),
                selected: on,
                onSelected: (_) => tap(),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _typed(BuildContext context, {TextInputType? keyboard}) {
    final shown = value is List ? (value as List).join(', ') : value;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(spec.label),
      subtitle: Text(
        shown == null ? 'Default. ${spec.help}' : '$shown. ${spec.help}',
      ),
      trailing: value == null
          ? const Icon(Icons.edit_outlined)
          : IconButton(
              tooltip: 'Back to default',
              icon: const Icon(Icons.close),
              onPressed: () => _set(null),
            ),
      onTap: () async {
        final entered = await _ask(
          context,
          spec.label,
          initial: shown == null ? '' : '$shown',
          hint: spec.hint,
          keyboard: keyboard,
        );
        if (entered == null) return;
        final t = entered.trim();
        _set(switch (spec.kind) {
          ParamKind.integer => int.tryParse(t),
          ParamKind.list => stopWords(t),
          _ => t.isEmpty ? null : t,
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    switch (spec.kind) {
      case ParamKind.slider:
        final v = value is num ? (value as num).toDouble() : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(spec.label),
              subtitle: Text(
                v == null
                    ? 'Default. ${spec.help}'
                    : '${_fmt(v)}. ${spec.help}',
              ),
              value: v != null,
              onChanged: (on) => _set(on ? spec.start : null),
            ),
            if (v != null)
              Slider(
                value: v.clamp(spec.min, spec.max),
                min: spec.min,
                max: spec.max,
                divisions: ((spec.max - spec.min) / spec.step).round(),
                label: _fmt(v),
                onChanged: (x) => _set(double.parse(x.toStringAsFixed(2))),
              ),
          ],
        );
      case ParamKind.integer:
        return _typed(
          context,
          keyboard: const TextInputType.numberWithOptions(signed: true),
        );
      case ParamKind.text:
      case ParamKind.list:
        return _typed(context);
      case ParamKind.toggle:
        return _chips(context, [
          ('Default', value == null, () => _set(null)),
          ('On', value == true, () => _set(true)),
          ('Off', value == false, () => _set(false)),
        ]);
      case ParamKind.choice:
        final known = spec.options.containsKey(value);
        return _chips(context, [
          ('Default', value == null, () => _set(null)),
          for (final o in spec.options.entries)
            (o.value, value == o.key, () => _set(o.key)),
          if (spec.other)
            (
              value != null && !known ? '$value' : 'Other…',
              value != null && !known,
              () async {
                final t = await _ask(
                  context,
                  spec.label,
                  initial: value != null && !known ? '$value' : '',
                );
                if (t != null) _set(t.trim().isEmpty ? null : t.trim());
              },
            ),
        ]);
      case ParamKind.tags:
        final custom = value is List && (value as List).length == 2;
        return _chips(context, [
          ('Default', value == null, () => _set(null)),
          ('Off', value == false, () => _set(false)),
          (
            custom
                ? '${(value as List)[0]} … ${(value as List)[1]}'
                : 'Custom…',
            custom,
            () async {
              final start = await _ask(
                context,
                'Start tag',
                initial: custom ? '${(value as List)[0]}' : '<think>',
                hint: '<think>',
              );
              if (start == null || start.trim().isEmpty || !context.mounted) {
                return;
              }
              final end = await _ask(
                context,
                'End tag',
                initial: custom ? '${(value as List)[1]}' : '</think>',
                hint: '</think>',
              );
              if (end == null || end.trim().isEmpty) return;
              _set([start.trim(), end.trim()]);
            },
          ),
        ]);
    }
  }
}

/// Any other setting the model takes, by name, as the web's "Add Custom
/// Parameter". Values that read as JSON are sent as such by the server.
class _CustomParams extends StatelessWidget {
  const _CustomParams({required this.value, required this.onChanged});

  final Map<String, dynamic> value;
  final void Function(Map<String, dynamic>) onChanged;

  Future<void> _edit(BuildContext context, [String? name]) async {
    final key =
        name ??
        (await _ask(
          context,
          'Parameter name',
          hint: 'Like response_format',
        ))?.trim();
    if (key == null || key.isEmpty || !context.mounted) return;
    final v = await _ask(
      context,
      key,
      initial: value[key] == null ? '' : '${value[key]}',
      hint: 'Value (text or JSON)',
    );
    if (v == null) return;
    final next = {...value};
    v.trim().isEmpty ? next.remove(key) : next[key] = v.trim();
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Custom parameters',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
        for (final e in value.entries)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(e.key),
            subtitle: Text('${e.value}', style: TextStyle(color: muted)),
            onTap: () => _edit(context, e.key),
            trailing: IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.close),
              onPressed: () => onChanged({...value}..remove(e.key)),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _edit(context),
            icon: const Icon(Icons.add),
            label: const Text('Add custom parameter'),
          ),
        ),
      ],
    );
  }
}
