/// Controls for one chat, as in the web UI's Controls panel: its own system
/// prompt and model settings, saved with the chat on the server.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workspace/tools_skills.dart' show ValvesScreen;
import 'chat_controller.dart';

Future<void> showChatControls(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _ChatControls(),
    );

/// A setting with a slider, as on the web: off means the default.
typedef _Slider = ({
  String key,
  String label,
  String help,
  double min,
  double max,
  double start,
  int divisions,
});

const _sliders = <_Slider>[
  (
    key: 'temperature',
    label: 'Temperature',
    help: 'Higher is more creative, lower more focused.',
    min: 0,
    max: 2,
    start: 0.8,
    divisions: 40,
  ),
  (
    key: 'top_p',
    label: 'Top P',
    help: 'Lower keeps to the likeliest words.',
    min: 0,
    max: 1,
    start: 0.9,
    divisions: 20,
  ),
];

class _ChatControls extends ConsumerStatefulWidget {
  const _ChatControls();

  @override
  ConsumerState<_ChatControls> createState() => _ChatControlsState();
}

class _ChatControlsState extends ConsumerState<_ChatControls> {
  late final _system = TextEditingController(
    text: '${ref.read(chatControllerProvider).params['system'] ?? ''}',
  );
  Timer? _save;

  ChatController get _chat => ref.read(chatControllerProvider.notifier);

  @override
  void dispose() {
    // Whatever was still being typed is saved on the way out.
    if (_save?.isActive ?? false) {
      _save!.cancel();
      unawaited(_chat.setParam('system', _system.text));
    }
    _system.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final params = ref.watch(chatControllerProvider.select((s) => s.params));
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
      child: Text(text, style: theme.textTheme.titleSmall),
    );

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Chat controls',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                if (params.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      _system.clear();
                      for (final k in params.keys.toList()) {
                        await _chat.setParam(k, null);
                      }
                    },
                    child: const Text('Reset all'),
                  ),
              ],
            ),
            Text(
              'Only for this chat, and saved with it. Anything left on '
              'default follows Settings and the model.',
              style: TextStyle(color: muted),
            ),
            heading('System prompt'),
            TextField(
              controller: _system,
              minLines: 2,
              maxLines: 8,
              decoration: const InputDecoration(
                hintText: 'How Nexus should act in this chat',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) {
                _save?.cancel();
                _save = Timer(
                  const Duration(milliseconds: 800),
                  () => _chat.setParam('system', v),
                );
              },
            ),
            heading('Model settings'),
            for (final s in _sliders) _slider(s, params[s.key], muted),
            _number(
              'max_tokens',
              'Max tokens',
              'Longest reply allowed.',
              params,
            ),
            _number('seed', 'Seed', 'The same seed repeats an answer.', params),
            _choice('reasoning_effort', 'Reasoning effort', const [
              'low',
              'medium',
              'high',
            ], params),
            _choice('function_calling', 'Tool calling', const [
              'native',
            ], params),
            ..._valves(heading),
          ],
        ),
      ),
    );
  }

  Widget _slider(_Slider s, Object? value, Color muted) {
    final v = value is num ? value.toDouble() : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(s.label),
          subtitle: Text(
            v == null ? 'Default. ${s.help}' : '${_fmt(v)}. ${s.help}',
          ),
          value: v != null,
          onChanged: (on) => _chat.setParam(s.key, on ? s.start : null),
        ),
        if (v != null)
          Slider(
            value: v.clamp(s.min, s.max),
            min: s.min,
            max: s.max,
            divisions: s.divisions,
            label: _fmt(v),
            onChanged: (x) =>
                _chat.setParam(s.key, double.parse(x.toStringAsFixed(2))),
          ),
      ],
    );
  }

  Widget _number(
    String key,
    String label,
    String help,
    Map<String, dynamic> params,
  ) {
    final v = params[key];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: Text(v == null ? 'Default. $help' : '$v. $help'),
      trailing: v == null
          ? const Icon(Icons.edit_outlined)
          : IconButton(
              tooltip: 'Back to default',
              icon: const Icon(Icons.close),
              onPressed: () => _chat.setParam(key, null),
            ),
      onTap: () async {
        final text = TextEditingController(text: v == null ? '' : '$v');
        final entered = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(label),
            content: TextField(
              controller: text,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(hintText: 'Empty for default'),
              onSubmitted: (x) => Navigator.pop(context, x),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, text.text),
                child: const Text('Save'),
              ),
            ],
          ),
        );
        text.dispose();
        if (entered == null) return;
        await _chat.setParam(key, int.tryParse(entered.trim()));
      },
    );
  }

  Widget _choice(
    String key,
    String label,
    List<String> options,
    Map<String, dynamic> params,
  ) {
    final v = params[key];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              ChoiceChip(
                label: const Text('Default'),
                selected: v == null,
                onSelected: (_) => _chat.setParam(key, null),
              ),
              for (final o in options)
                ChoiceChip(
                  label: Text(o[0].toUpperCase() + o.substring(1)),
                  selected: v == o,
                  onSelected: (_) => _chat.setParam(key, o),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Your own settings for the tools and filters this chat uses, as the
  /// web's Valves section has. They're yours, so they apply in every chat.
  List<Widget> _valves(Widget Function(String) heading) {
    final state = ref.watch(chatControllerProvider);
    final model = ref
        .watch(modelsProvider)
        .value
        ?.where((m) => m.id == state.modelId)
        .firstOrNull;
    final names = {
      for (final t in ref.watch(toolsProvider).value ?? const []) t.id: t.name,
    };
    final tools = state.toolIds ?? model?.toolIds.toSet() ?? const {};
    final filters = model?.defaultFilterIds ?? const [];
    if (tools.isEmpty && filters.isEmpty) return const [];
    Widget tile(String name, String base) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.tune),
      title: Text(name),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ValvesScreen(
            title: name,
            specPath: '$base/valves/user/spec',
            valuesPath: '$base/valves/user',
            savePath: '$base/valves/user/update',
          ),
        ),
      ),
    );
    return [
      heading('Valves'),
      Text(
        'Your settings for the tools this chat uses. They apply wherever '
        'you use the tool.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      for (final id in tools) tile(names[id] ?? id, '/api/v1/tools/id/$id'),
      for (final id in filters) tile(id, '/api/v1/functions/id/$id'),
    ];
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(1) : '$v';
}
