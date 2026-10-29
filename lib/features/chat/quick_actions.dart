/// Quick actions on selected reply text, as the web's floating buttons:
/// Ask and Explain (or your own, from Settings > Interface) put the
/// selection, quoted, into the chat box.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../settings/settings_screen.dart'
    show settingsApiProvider, uiSettingsProvider;
import 'chat_controller.dart' show userSettingsProvider;
import 'composer_draft.dart';
import '../../core/i18n/app_strings.dart';

const defaultQuickActions = <Map<String, dynamic>>[
  {
    'id': 'ask',
    'label': 'Ask',
    'input': true,
    'prompt': '{{SELECTED_CONTENT}}\n\n\n{{INPUT_CONTENT}}',
  },
  {
    'id': 'explain',
    'label': 'Explain',
    'input': false,
    'prompt': '{{SELECTED_CONTENT}}\n\n\nExplain',
  },
];

/// Your actions, or Ask and Explain when you haven't set any.
List<Map<String, dynamic>> quickActions(Map? ui) {
  final mine = [
    for (final a in ui?['floatingActionButtons'] as List? ?? const [])
      if (a is Map) a.cast<String, dynamic>(),
  ];
  return mine.isEmpty ? defaultQuickActions : mine;
}

/// The chat box text for [action] on [selected], as the web builds it; an
/// action that asks for input leaves the end for you to type.
String quickActionPrompt(Map action, String selected) {
  final quoted = selected.split('\n').map((l) => '> $l').join('\n');
  return '${action['prompt'] ?? ''}'
      .replaceAllMapped(
        RegExp(r'\{\{([^{}|]*?)\|tool:id="([^"]+)"\}\}'),
        (m) => m[1]!,
      )
      .replaceAll(RegExp(r'\{\{TOOL:([^}]+)\}\}'), '')
      .replaceFirst('{{INPUT_CONTENT}}', '')
      .replaceFirst('{{CONTENT}}', selected)
      .replaceFirst('{{SELECTED_CONTENT}}', quoted);
}

/// Makes [child] selectable, with the quick actions beside Copy.
class QuickActionSelection extends ConsumerStatefulWidget {
  const QuickActionSelection({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<QuickActionSelection> createState() =>
      _QuickActionSelectionState();
}

class _QuickActionSelectionState extends ConsumerState<QuickActionSelection> {
  String _selected = '';

  @override
  Widget build(BuildContext context) {
    final ui = (ref.watch(userSettingsProvider).value?['ui'] as Map?) ?? {};
    final show = ui['showFloatingActionButtons'] != false;
    return SelectionArea(
      onSelectionChanged: (c) => _selected = c?.plainText ?? '',
      contextMenuBuilder: (context, state) =>
          AdaptiveTextSelectionToolbar.buttonItems(
            anchors: state.contextMenuAnchors,
            buttonItems: [
              ...state.contextMenuButtonItems,
              if (show)
                for (final a in quickActions(ui))
                  ContextMenuButtonItem(
                    label: '${a['label'] ?? a['id']}',
                    onPressed: () {
                      final text = _selected.trim();
                      state.hideToolbar();
                      state.clearSelection();
                      if (text.isEmpty) return;
                      ref
                          .read(composerDraftProvider.notifier)
                          .put(quickActionPrompt(a, text));
                    },
                  ),
            ],
          ),
      child: widget.child,
    );
  }
}

/// Settings > Interface > Quick Actions.
class QuickActionsScreen extends ConsumerStatefulWidget {
  const QuickActionsScreen({super.key});

  @override
  ConsumerState<QuickActionsScreen> createState() => _QuickActionsScreenState();
}

class _QuickActionsScreenState extends ConsumerState<QuickActionsScreen> {
  List<Map<String, dynamic>>? _actions;
  bool _busy = false;

  Future<void> _save(List<Map<String, dynamic>>? actions) async {
    setState(() => _busy = true);
    try {
      await ref.read(settingsApiProvider).patchUi({
        'floatingActionButtons': actions,
      });
      ref
        ..invalidate(uiSettingsProvider)
        ..invalidate(userSettingsProvider);
      setState(() => _actions = actions == null ? null : [...actions]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<Map<String, dynamic>?> _edit([Map<String, dynamic>? action]) {
    final label = TextEditingController(text: '${action?['label'] ?? ''}');
    final prompt = TextEditingController(
      text: '${action?['prompt'] ?? '{{SELECTED_CONTENT}}\n\n\n'}',
    );
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(action == null ? 'New Button' : 'Edit action'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: label,
                autofocus: true,
                decoration: InputDecoration(labelText: tr('Title')),
              ),
              TextField(
                controller: prompt,
                minLines: 3,
                maxLines: 8,
                decoration: InputDecoration(
                  labelText: tr('Prompt'),
                  helperText: tr(
                    '{{SELECTED_CONTENT}} is the selection quoted, '
                    '{{CONTENT}} as is, {{INPUT_CONTENT}} what you type.',
                  ),
                  helperMaxLines: 3,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (label.text.trim().isEmpty) return;
              Navigator.pop(d, {
                'id':
                    action?['id'] ??
                    '${label.text.trim().toLowerCase().replaceAll(RegExp(r'\W+'), '_')}'
                        '_${DateTime.now().millisecondsSinceEpoch}',
                'label': label.text.trim(),
                'input': prompt.text.contains('{{INPUT_CONTENT}}'),
                'prompt': prompt.text,
              });
            },
            child: const T('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(uiSettingsProvider).value;
    final actions = _actions ??= ui == null ? null : [...quickActions(ui)];
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const T('Quick Actions'),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => _save(null),
            child: const T('Reset'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy || actions == null
            ? null
            : () async {
                final made = await _edit();
                if (made != null) await _save([...actions, made]);
              },
        icon: const Icon(Icons.add),
        label: const T('New Button'),
      ),
      body: actions == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: T(
                    'Select text in a reply to see these next to Copy. They '
                    'put the selection into the chat box.',
                    style: TextStyle(color: muted),
                  ),
                ),
                for (final (i, a) in actions.indexed)
                  ListTile(
                    title: Text('${a['label'] ?? a['id']}'),
                    subtitle: Text(
                      '${a['prompt'] ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted),
                    ),
                    onTap: () async {
                      final changed = await _edit(a);
                      if (changed != null) {
                        await _save([...actions]..[i] = changed);
                      }
                    },
                    trailing: IconButton(
                      tooltip: tr('Remove action'),
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: _busy
                          ? null
                          : () => _save([...actions]..removeAt(i)),
                    ),
                  ),
              ],
            ),
    );
  }
}
