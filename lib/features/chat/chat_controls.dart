/// Controls for one chat, as in the web UI's Controls panel: its own system
/// prompt and model settings, saved with the chat on the server.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workspace/tools_skills.dart' show ValvesScreen;
import 'advanced_params.dart';
import 'chat_controller.dart';
import '../settings/tool_servers.dart' show chatToolsProvider;

Future<void> showChatControls(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const ChatControlsView(),
    );

/// The controls themselves: in a sheet, or as the Controls tab of the
/// chat panel ([inPanel]).
class ChatControlsView extends ConsumerStatefulWidget {
  const ChatControlsView({super.key, this.inPanel = false});
  final bool inPanel;

  @override
  ConsumerState<ChatControlsView> createState() => _ChatControlsState();
}

class _ChatControlsState extends ConsumerState<ChatControlsView> {
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

    final list = ListView(
      padding: EdgeInsets.fromLTRB(
        20,
        widget.inPanel ? 8 : 0,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.inPanel ? 'This chat' : 'Chat controls',
                style: widget.inPanel
                    ? theme.textTheme.titleMedium
                    : theme.textTheme.titleLarge,
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
        AdvancedParamsEditor(params: params, onChanged: _chat.setParam),
        ..._valves(heading),
      ],
    );
    if (widget.inPanel) return list;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: list,
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
      for (final t in ref.watch(chatToolsProvider).value ?? const [])
        t.id: t.name,
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
}
