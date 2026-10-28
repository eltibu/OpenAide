/// Running a phone action from the chat box, a dictation or a call.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_controller.dart' show userSettingsProvider;
import 'phone_actions.dart';

/// Runs [text] as a phone action when it is one (and they're switched on);
/// returns what was done, or null to send it to Nexus as a message.
Future<String?> tryPhoneAction(
  BuildContext context,
  WidgetRef ref,
  String text,
) async {
  final ui = ref.read(userSettingsProvider).value?['ui'] as Map?;
  if (!phoneActionsOn(ui)) return null;
  final action = parsePhoneAction(text);
  if (action == null) return null;
  final said = await runPhoneAction(
    action,
    pick: (people) => pickContactSheet(context, people),
  );
  if (said != null && said.isNotEmpty && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(said)));
  }
  return said;
}

/// Asks which of [people] (with the same name) was meant.
Future<Map?> pickContactSheet(BuildContext context, List<Map> people) =>
    showModalBottomSheet<Map>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final p in people)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text('${p['name']}'),
                subtitle: Text('${p['number']}'),
                onTap: () => Navigator.pop(c, p),
              ),
          ],
        ),
      ),
    );
