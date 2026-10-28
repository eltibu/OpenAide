/// Tool Permissions in the "+" menu, as the web's: run tools without asking,
/// or stop before each tool call until you allow or deny it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/settings_screen.dart'
    show settingsApiProvider, uiSettingsProvider;
import 'chat_controller.dart';

const toolApprovalModes = {
  'full': ('Full access', 'Run tools without asking for approval.'),
  'ask': (
    'Ask for approval',
    'Stop before each tool call until you allow or deny it.',
  ),
};

/// The chat's own choice, else your default, as the web reads it.
String toolApprovalMode(Map<String, dynamic> chatParams, Map? ui) =>
    (chatParams['tool_approval_mode'] ??
            (ui?['params'] as Map?)?['tool_approval_mode']) ==
        'ask'
    ? 'ask'
    : 'full';

Future<void> pickToolApprovalMode(
  BuildContext context,
  WidgetRef ref,
  String current,
) async {
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Tool Permissions')),
          for (final m in toolApprovalModes.entries)
            ListTile(
              leading: Icon(
                m.key == current ? Icons.check : null,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(m.value.$1),
              subtitle: Text(m.value.$2),
              onTap: () => Navigator.pop(context, m.key),
            ),
        ],
      ),
    ),
  );
  if (picked == null || picked == current) return;
  // As the web: this chat keeps it, and it becomes your default too.
  await ref
      .read(chatControllerProvider.notifier)
      .setParam('tool_approval_mode', picked);
  final ui = ref.read(userSettingsProvider).value?['ui'] as Map?;
  try {
    await ref.read(settingsApiProvider).patchUi({
      'params': {...?(ui?['params'] as Map?), 'tool_approval_mode': picked},
    });
  } catch (_) {}
  ref
    ..invalidate(userSettingsProvider)
    ..invalidate(uiSettingsProvider);
}
