/// Model controls, as the web's: a model's admin gives it named choices
/// (say "Thinking: Low, Medium, High"), each setting some of its
/// parameters. In a chat you pick one from the Model controls button; the
/// pick is kept in your settings on the server and goes with every message,
/// where the server applies it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/model_info.dart';
import '../../core/theme.dart';
import '../settings/settings_screen.dart'
    show settingsApiProvider, uiSettingsProvider;
import 'chat_controller.dart';
import '../../core/i18n/app_strings.dart';

/// One choice of a control: its name and the parameters it sets.
typedef ControlOption = ({
  String key,
  String label,
  Map<String, dynamic> params,
});

class ModelControl {
  const ModelControl({
    required this.key,
    required this.label,
    this.description = '',
    this.slider = false,
    this.defaultOption,
    this.options = const [],
  });

  final String key;
  final String label;
  final String description;

  /// Shown as a slider rather than a list.
  final bool slider;
  final String? defaultOption;
  final List<ControlOption> options;

  ModelControl copyWith({
    String? label,
    String? description,
    bool? slider,
    String? Function()? defaultOption,
    List<ControlOption>? options,
  }) => ModelControl(
    key: key,
    label: label ?? this.label,
    description: description ?? this.description,
    slider: slider ?? this.slider,
    defaultOption: defaultOption == null ? this.defaultOption : defaultOption(),
    options: options ?? this.options,
  );
}

/// A model's controls as saved in its `params.model_controls`.
List<ModelControl> readModelControls(Object? raw) => [
  if (raw is Map)
    for (final MapEntry(:key, :value) in raw.entries)
      if (value is Map)
        ModelControl(
          key: '$key',
          label: '${value['label'] ?? key}',
          description: '${value['description'] ?? ''}',
          slider: value['display'] == 'slider',
          defaultOption: value['default'] as String?,
          options: [
            if (value['options'] is Map)
              for (final o in (value['options'] as Map).entries)
                if (o.value is Map)
                  (
                    key: '${o.key}',
                    label: '${(o.value as Map)['label'] ?? o.key}',
                    params:
                        ((o.value as Map)['params'] as Map?)
                            ?.cast<String, dynamic>() ??
                        const {},
                  ),
          ],
        ),
];

/// Back to how the server keeps them.
Map<String, dynamic> writeModelControls(List<ModelControl> controls) => {
  for (final c in controls)
    c.key: {
      'label': c.label.trim(),
      if (c.slider) 'display': 'slider',
      if (c.description.trim().isNotEmpty) 'description': c.description.trim(),
      'default': c.defaultOption,
      'options': {
        for (final o in c.options)
          o.key: {'label': o.label.trim(), 'params': o.params},
      },
    },
};

/// A key from a name, not clashing with [taken], as the web makes them.
String controlKey(String label, Iterable<String> taken) {
  var base = label
      .toLowerCase()
      .trim()
      .replaceAll(RegExp('[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  if (!RegExp('^[a-z]').hasMatch(base) ||
      base == 'constructor' ||
      base == 'prototype') {
    base = 'option_$base';
  }
  final used = taken.toSet();
  var key = base;
  for (var i = 2; used.contains(key); i++) {
    key = '${base}_$i';
  }
  return key;
}

/// The controls of a model as the chat sees it.
List<ModelControl> controlsOf(ModelInfo? model) => readModelControls(
  ((model?.raw['info'] as Map?)?['params'] as Map?)?['model_controls'],
);

/// Your picks: model → control → option.
Map<String, Map<String, String>> chosenControls(Map? ui) => {
  for (final e
      in (((ui?['params'] as Map?)?['model_controls'] as Map?) ?? const {})
          .entries)
    if (e.value is Map)
      '${e.key}': {
        for (final c in (e.value as Map).entries) '${c.key}': '${c.value}',
      },
};

/// A parameter value as typed: a number, true/false or JSON when it reads
/// as one, else the text.
Object? paramValue(String text) {
  final t = text.trim();
  if (t.isEmpty) return '';
  try {
    return jsonDecode(t);
  } catch (_) {
    return text;
  }
}

String paramText(Object? value) => value is String ? value : jsonEncode(value);

/// The Model controls button beside the chat box: only there when a model
/// in this chat has controls.
class ModelControlsButton extends ConsumerWidget {
  const ModelControlsButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatControllerProvider);
    final models = ref.watch(modelsProvider).value ?? const <ModelInfo>[];
    final ids = {?state.modelId, ...state.compareIds};
    final withControls = [
      for (final m in models)
        if (ids.contains(m.id) && controlsOf(m).isNotEmpty) m,
    ];
    if (withControls.isEmpty) return const SizedBox.shrink();
    final picked = chosenControls(ref.watch(uiSettingsProvider).value).entries
        .where((e) => ids.contains(e.key))
        .any((e) => e.value.isNotEmpty);
    return IconButton(
      tooltip: tr('Model controls'),
      visualDensity: VisualDensity.compact,
      color: picked ? NexusColors.accent : context.nexus.muted,
      icon: const Icon(Icons.tune_rounded),
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _ControlsSheet(models: withControls),
      ),
    );
  }
}

class _ControlsSheet extends ConsumerStatefulWidget {
  const _ControlsSheet({required this.models});
  final List<ModelInfo> models;

  @override
  ConsumerState<_ControlsSheet> createState() => _ControlsSheetState();
}

class _ControlsSheetState extends ConsumerState<_ControlsSheet> {
  bool _saving = false;

  Future<void> _pick(String model, String control, String? option) async {
    final ui = ref.read(uiSettingsProvider).value ?? const {};
    final params = {...?(ui['params'] as Map?)?.cast<String, dynamic>()};
    final all = chosenControls(ui);
    final mine = {...?all[model]};
    option == null ? mine.remove(control) : mine[control] = option;
    all[model] = mine;
    params['model_controls'] = all;
    setState(() => _saving = true);
    try {
      await ref.read(settingsApiProvider).patchUi({'params': params});
      ref
        ..invalidate(uiSettingsProvider)
        ..invalidate(userSettingsProvider);
      await ref.read(uiSettingsProvider.future);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final chosen = chosenControls(ref.watch(uiSettingsProvider).value);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Row(
              children: [
                T(
                  'Model controls',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                if (_saving)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            for (final m in widget.models) ...[
              if (widget.models.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(m.name, style: TextStyle(color: muted)),
                ),
              for (final c in controlsOf(m))
                _ControlRow(
                  control: c,
                  chosen: chosen[m.id]?[c.key],
                  onPick: _saving ? null : (o) => _pick(m.id, c.key, o),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ControlRow extends StatelessWidget {
  const _ControlRow({
    required this.control,
    required this.chosen,
    required this.onPick,
  });
  final ModelControl control;
  final String? chosen;

  /// null: back to the model's default.
  final ValueChanged<String?>? onPick;

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final c = control;
    final current = c.options.any((o) => o.key == chosen) ? chosen : null;
    final shown = current ?? c.defaultOption;
    final label = c.options.where((o) => o.key == shown).firstOrNull?.label;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(c.label)),
              Text(
                current == null
                    ? 'Default${label == null ? '' : ' · $label'}'
                    : label ?? '',
                style: TextStyle(color: muted),
              ),
            ],
          ),
          if (c.description.isNotEmpty)
            Text(c.description, style: TextStyle(color: muted, fontSize: 12)),
          if (c.slider && c.options.length > 1)
            Slider(
              value: c.options
                  .indexWhere((o) => o.key == shown)
                  .clamp(0, c.options.length - 1)
                  .toDouble(),
              max: c.options.length - 1.0,
              divisions: c.options.length - 1,
              label: label,
              onChanged: onPick == null
                  ? null
                  : (v) => onPick!(c.options[v.round()].key),
            )
          else
            Wrap(
              spacing: 6,
              children: [
                for (final o in c.options)
                  ChoiceChip(
                    label: Text(o.label),
                    selected: shown == o.key,
                    onSelected: onPick == null ? null : (_) => onPick!(o.key),
                  ),
              ],
            ),
          if (current != null)
            TextButton(
              onPressed: onPick == null ? null : () => onPick!(null),
              child: const T('Default'),
            ),
        ],
      ),
    );
  }
}

/// The model editor's Model controls: add, change, reorder and remove.
class ModelControlsEditor extends StatelessWidget {
  const ModelControlsEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final List<ModelControl> value;
  final ValueChanged<List<ModelControl>> onChanged;

  Future<void> _edit(BuildContext context, [int? index]) async {
    final old = index == null ? null : value[index];
    final result = await Navigator.push<ModelControl?>(
      context,
      MaterialPageRoute(
        builder: (_) => _ControlEditor(
          control: old,
          taken: [
            for (final c in value)
              if (c.key != old?.key) c.key,
          ],
        ),
      ),
    );
    if (result == null) return;
    final list = [...value];
    if (result.key.isEmpty) {
      list.removeAt(index!);
    } else if (index == null) {
      list.add(result);
    } else {
      list[index] = result;
    }
    onChanged(list);
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const T('Model controls'),
      subtitle: Text(
        value.isEmpty
            ? 'Choices people can pick in a chat'
            : '${value.length} control${value.length == 1 ? '' : 's'}',
      ),
      children: [
        for (var i = 0; i < value.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(value[i].label),
            subtitle: Text(
              value[i].options.map((o) => o.label).join(', '),
              style: TextStyle(color: muted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: i == 0
                ? null
                : IconButton(
                    tooltip: tr('Move up'),
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: () {
                      final list = [...value];
                      list.insert(i - 1, list.removeAt(i));
                      onChanged(list);
                    },
                  ),
            onTap: () => _edit(context, i),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _edit(context),
            icon: const Icon(Icons.add),
            label: const T('Add control'),
          ),
        ),
      ],
    );
  }
}

/// One option being edited: its name and parameter rows.
class _OptionDraft {
  _OptionDraft(this.key, String label, Map<String, dynamic> params)
    : label = TextEditingController(text: label),
      params = [
        for (final e in params.entries)
          (
            TextEditingController(text: e.key),
            TextEditingController(text: paramText(e.value)),
          ),
      ];
  final String? key;
  final TextEditingController label;
  final List<(TextEditingController, TextEditingController)> params;
  final id = UniqueKey();

  void dispose() {
    label.dispose();
    for (final (a, b) in params) {
      a.dispose();
      b.dispose();
    }
  }
}

/// Pops the control, one with an empty key to remove it, or null.
class _ControlEditor extends StatefulWidget {
  const _ControlEditor({this.control, required this.taken});
  final ModelControl? control;
  final List<String> taken;

  @override
  State<_ControlEditor> createState() => _ControlEditorState();
}

class _ControlEditorState extends State<_ControlEditor> {
  late final _label = TextEditingController(text: widget.control?.label);
  late final _description = TextEditingController(
    text: widget.control?.description,
  );
  late bool _slider = widget.control?.slider ?? false;
  late final List<_OptionDraft> _options = [
    for (final o in widget.control?.options ?? const <ControlOption>[])
      _OptionDraft(o.key, o.label, o.params),
  ];
  late Key? _default = _options
      .where((o) => o.key == widget.control?.defaultOption)
      .firstOrNull
      ?.id;

  @override
  void initState() {
    super.initState();
    if (_options.isEmpty) _options.add(_OptionDraft(null, '', {'': ''}));
  }

  @override
  void dispose() {
    _label.dispose();
    _description.dispose();
    for (final o in _options) {
      o.dispose();
    }
    super.dispose();
  }

  void _done() {
    if (_label.text.trim().isEmpty) return;
    final keys = <String>{
      for (final o in _options)
        if (o.key != null) o.key!,
    };
    String? chosen;
    final options = <ControlOption>[];
    for (final o in _options) {
      if (o.label.text.trim().isEmpty) continue;
      final key = o.key ?? controlKey(o.label.text, keys);
      keys.add(key);
      if (o.id == _default) chosen = key;
      options.add((
        key: key,
        label: o.label.text.trim(),
        params: {
          for (final (k, v) in o.params)
            if (k.text.trim().isNotEmpty) k.text.trim(): paramValue(v.text),
        },
      ));
    }
    Navigator.pop(
      context,
      ModelControl(
        key: widget.control?.key ?? controlKey(_label.text, widget.taken),
        label: _label.text.trim(),
        description: _description.text.trim(),
        slider: _slider,
        defaultOption: chosen,
        options: options,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.control == null ? 'Add control' : 'Edit control'),
        actions: [
          if (widget.control != null)
            IconButton(
              tooltip: tr('Remove'),
              icon: const Icon(Icons.delete_outline),
              onPressed: () => Navigator.pop(
                context,
                const ModelControl(key: '', label: ''),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _done, child: const T('Done')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            controller: _label,
            autofocus: widget.control == null,
            decoration: InputDecoration(
              labelText: tr('Name'),
              hintText: tr('Thinking'),
            ),
          ),
          TextField(
            controller: _description,
            decoration: InputDecoration(
              labelText: tr('Description (optional)'),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const T('Show as'),
              const SizedBox(width: 12),
              ChoiceChip(
                label: const T('Menu'),
                selected: !_slider,
                onSelected: (_) => setState(() => _slider = false),
              ),
              const SizedBox(width: 6),
              ChoiceChip(
                label: const T('Slider'),
                selected: _slider,
                onSelected: (_) => setState(() => _slider = true),
              ),
            ],
          ),
          const SizedBox(height: 16),
          T('Options', style: Theme.of(context).textTheme.titleSmall),
          T(
            'Each sets parameters, like reasoning_effort: high. The one '
            'starred is used until someone picks another.',
            style: TextStyle(color: muted, fontSize: 12),
          ),
          for (var i = 0; i < _options.length; i++)
            Card(
              key: _options[i].id,
              margin: const EdgeInsets.only(top: 8),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _options[i].label,
                            decoration: InputDecoration(
                              labelText: tr('Option name'),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: tr('Default'),
                          icon: Icon(
                            _default == _options[i].id
                                ? Icons.star
                                : Icons.star_border,
                            color: _default == _options[i].id
                                ? NexusColors.accent
                                : null,
                          ),
                          onPressed: () => setState(
                            () => _default = _default == _options[i].id
                                ? null
                                : _options[i].id,
                          ),
                        ),
                        if (i > 0)
                          IconButton(
                            tooltip: tr('Move up'),
                            icon: const Icon(Icons.arrow_upward),
                            onPressed: () => setState(
                              () =>
                                  _options.insert(i - 1, _options.removeAt(i)),
                            ),
                          ),
                        IconButton(
                          tooltip: tr('Remove option'),
                          icon: const Icon(Icons.close),
                          onPressed: () =>
                              setState(() => _options.removeAt(i).dispose()),
                        ),
                      ],
                    ),
                    for (var j = 0; j < _options[i].params.length; j++)
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _options[i].params[j].$1,
                              decoration: InputDecoration(
                                hintText: tr('Parameter'),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _options[i].params[j].$2,
                              decoration: InputDecoration(
                                hintText: tr('Value'),
                                isDense: true,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: tr('Remove parameter'),
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () => setState(() {
                              final (a, b) = _options[i].params.removeAt(j);
                              a.dispose();
                              b.dispose();
                            }),
                          ),
                        ],
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setState(
                          () => _options[i].params.add((
                            TextEditingController(),
                            TextEditingController(),
                          )),
                        ),
                        icon: const Icon(Icons.add, size: 18),
                        label: const T('Parameter'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(
                () => _options.add(_OptionDraft(null, '', {'': ''})),
              ),
              icon: const Icon(Icons.add),
              label: const T('Add option'),
            ),
          ),
        ],
      ),
    );
  }
}
