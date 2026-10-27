import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import 'prompts_api.dart';

final promptsApiProvider = Provider<PromptsApi>(
  (ref) => PromptsApi(ref.watch(clientProvider)),
);

/// Prompts that can be used in chat.
final promptsProvider = FutureProvider<List<Prompt>>((ref) async {
  try {
    return await ref.watch(promptsApiProvider).active();
  } catch (_) {
    return const [];
  }
});

/// Every prompt, for managing them.
final allPromptsProvider = FutureProvider<List<Prompt>>(
  (ref) => ref.watch(promptsApiProvider).list(),
);

/// A prompt ready to send: the app's values filled in, then the person's
/// answers to its placeholders. Null if they backed out.
Future<String?> resolvePrompt(
  BuildContext context,
  WidgetRef ref,
  Prompt prompt,
) async {
  final user = ref.read(sessionProvider).value?.user;
  String? clip;
  if (prompt.content.contains('{{CLIPBOARD}}')) {
    clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  }
  var text = fillSystemVariables(
    prompt.content,
    userName: user?['name'] as String?,
    userEmail: user?['email'] as String?,
    clipboard: clip,
  );
  final vars = inputVariables(text);
  if (vars.isEmpty) return text;
  if (!context.mounted) return null;
  final values = await showDialog<Map<String, String>>(
    context: context,
    builder: (_) => _VariablesDialog(title: prompt.name, vars: vars),
  );
  if (values == null) return null;
  return fillInputVariables(text, values);
}

class _VariablesDialog extends StatefulWidget {
  const _VariablesDialog({required this.title, required this.vars});
  final String title;
  final List<PromptVariable> vars;

  @override
  State<_VariablesDialog> createState() => _VariablesDialogState();
}

class _VariablesDialogState extends State<_VariablesDialog> {
  late final Map<String, TextEditingController> _text = {
    for (final v in widget.vars)
      v.name: TextEditingController(
        text: v.initial == null || v.initial is bool ? '' : '${v.initial}',
      ),
  };
  late final Map<String, String> _picked = {
    for (final v in widget.vars)
      if (v.type == 'select')
        v.name: v.initial != null
            ? '${v.initial}'
            : (v.options.isEmpty ? '' : v.options.first)
      else if (v.type == 'checkbox')
        v.name: '${v.initial == true}',
  };

  String _label(String name) => name.replaceAll('_', ' ');

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final v in widget.vars)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: switch (v.type) {
              'select' => DropdownButtonFormField<String>(
                initialValue: _picked[v.name]!.isEmpty ? null : _picked[v.name],
                decoration: InputDecoration(labelText: _label(v.name)),
                items: [
                  for (final o in v.options)
                    DropdownMenuItem(value: o, child: Text(o)),
                ],
                onChanged: (o) => setState(() => _picked[v.name] = o ?? ''),
              ),
              'checkbox' => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_label(v.name)),
                value: _picked[v.name] == 'true',
                onChanged: (on) => setState(() => _picked[v.name] = '$on'),
              ),
              _ => TextField(
                controller: _text[v.name],
                minLines: v.type == 'textarea' ? 3 : 1,
                maxLines: v.type == 'textarea' ? 8 : 1,
                keyboardType: v.type == 'number'
                    ? TextInputType.number
                    : v.type == 'email'
                    ? TextInputType.emailAddress
                    : v.type == 'url'
                    ? TextInputType.url
                    : null,
                decoration: InputDecoration(
                  labelText: _label(v.name) + (v.required ? ' *' : ''),
                  hintText: v.placeholder,
                ),
              ),
            },
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          for (final v in widget.vars) {
            if (v.required &&
                !_picked.containsKey(v.name) &&
                _text[v.name]!.text.trim().isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Fill in ${_label(v.name)}')),
              );
              return;
            }
          }
          Navigator.pop(context, {
            for (final v in widget.vars)
              v.name: _picked[v.name] ?? _text[v.name]!.text,
          });
        },
        child: const Text('Use'),
      ),
    ],
  );
}

/// Prompts that match what follows "/" in the text box.
/// One of the app's own "/" commands.
class SlashCommand {
  const SlashCommand(this.command, this.label, this.icon, this.run);
  final String command;
  final String label;
  final IconData icon;
  final VoidCallback run;
}

class PromptSuggestions extends ConsumerWidget {
  const PromptSuggestions({
    super.key,
    required this.query,
    required this.onPick,
    this.commands = const [],
  });
  final String query;
  final ValueChanged<Prompt> onPick;

  /// Built-in commands, shown before the saved prompts.
  final List<SlashCommand> commands;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = query.toLowerCase();
    final list = [
      for (final p in ref.watch(promptsProvider).value ?? const <Prompt>[])
        if (p.active &&
            (p.command.toLowerCase().contains(q) ||
                p.name.toLowerCase().contains(q)))
          p,
    ];
    final builtIn = [
      for (final c in commands)
        if (c.command.contains(q) || c.label.toLowerCase().contains(q)) c,
    ];
    if (list.isEmpty && builtIn.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(top: 6),
        children: [
          for (final c in builtIn)
            ListTile(
              dense: true,
              leading: Icon(c.icon, color: NexusColors.accent),
              title: Text('/${c.command}'),
              subtitle: Text(
                c.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: c.run,
            ),
          for (final p in list)
            ListTile(
              dense: true,
              leading: const Icon(Icons.bolt, color: NexusColors.accent),
              title: Text('/${p.command}'),
              subtitle: Text(
                p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onPick(p),
            ),
        ],
      ),
    );
  }
}

/// The person's prompts, to write, change, turn off or remove.
class PromptsScreen extends ConsumerWidget {
  const PromptsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prompts = ref.watch(allPromptsProvider);
    final muted = context.nexus.muted;
    Future<void> edit([Prompt? p]) async {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => PromptEditor(prompt: p)),
      );
      ref.invalidate(allPromptsProvider);
      ref.invalidate(promptsProvider);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Prompts')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New prompt',
        onPressed: edit,
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(allPromptsProvider.future),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text(
                'Type / in a chat to use one.',
                style: TextStyle(color: muted),
              ),
            ),
            if (prompts.hasError && !prompts.hasValue)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load prompts.\n${prompts.error}'),
              )
            else if (prompts.isLoading && !prompts.hasValue)
              const Center(child: CircularProgressIndicator()),
            for (final p in prompts.value ?? const <Prompt>[])
              ListTile(
                title: Text('/${p.command}'),
                subtitle: Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted),
                ),
                onTap: () => edit(p),
                trailing: Switch(
                  value: p.active,
                  onChanged: (_) async {
                    try {
                      await ref.read(promptsApiProvider).toggle(p.id);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text('$e')));
                      }
                    }
                    ref.invalidate(allPromptsProvider);
                    ref.invalidate(promptsProvider);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class PromptEditor extends ConsumerStatefulWidget {
  const PromptEditor({super.key, this.prompt});
  final Prompt? prompt;

  @override
  ConsumerState<PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends ConsumerState<PromptEditor> {
  late final Prompt? _p = widget.prompt;
  late final _name = TextEditingController(text: _p?.name ?? '');
  late final _command = TextEditingController(text: _p?.command ?? '');
  late final _content = TextEditingController(text: _p?.content ?? '');
  bool _busy = false;
  bool _commandEdited = false;

  String _slug(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[^a-z0-9_-]'), '');

  Future<void> _save() async {
    final command = _slug(_command.text);
    if (_name.text.trim().isEmpty ||
        command.isEmpty ||
        _content.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name, command and text are needed')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(promptsApiProvider)
          .save(
            _p?.id,
            command: command,
            name: _name.text.trim(),
            content: _content.text,
            tags: _p?.tags ?? const [],
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete /${_p!.command}?'),
        content: const Text('This can\'t be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(promptsApiProvider).delete(_p!.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_p == null ? 'New prompt' : 'Edit prompt'),
      actions: [
        if (_p != null)
          IconButton(
            tooltip: 'Delete',
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
          ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_p == null ? 'Create' : 'Save'),
          ),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          controller: _name,
          autofocus: _p == null,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (v) {
            if (_p == null && !_commandEdited) _command.text = _slug(v);
          },
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _command,
          onChanged: (_) => _commandEdited = true,
          decoration: const InputDecoration(
            labelText: 'Command',
            prefixText: '/',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _content,
          minLines: 8,
          maxLines: null,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Prompt',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Use {{CLIPBOARD}}, {{USER_NAME}}, {{CURRENT_DATE}} and the like, '
          'or {{name}} to be asked for a value when you use it.',
          style: TextStyle(color: context.nexus.muted, fontSize: 12),
        ),
      ],
    ),
  );
}
