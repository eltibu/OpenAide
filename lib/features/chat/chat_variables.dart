/// Chat Variables: fields a model's system prompt asks for
/// (`{{chat.variables.tone | select:options=["warm","brief"]}}`), answered
/// once per chat and kept with it, as on the web.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/model_info.dart';
import '../workspace/prompts_api.dart' show PromptVariable;
import '../workspace/prompts_screen.dart' show VariablesDialog;
import 'chat_controller.dart';

/// The fields of [modelIds]' schemas, merged by key (the first model's
/// definition wins; a field is required when any model needs it).
List<Map<String, dynamic>> chatVariableFields(
  List<ModelInfo> models,
  Iterable<String> modelIds,
) {
  final byKey = <String, Map<String, dynamic>>{};
  for (final id in modelIds) {
    final m = models.where((m) => m.id == id).firstOrNull;
    final schema = m?.meta['chat_variables_schema'] as Map?;
    for (final f in (schema?['fields'] as List? ?? const [])) {
      if (f is! Map || '${f['key'] ?? ''}'.isEmpty) continue;
      final field = {
        ...f.cast<String, dynamic>(),
        'type': f['type'] ?? 'text',
        'required': f['required'] == true,
      };
      final had = byKey[field['key']];
      if (had == null) {
        byKey['${field['key']}'] = field;
      } else if (field['required'] == true) {
        had['required'] = true;
      }
    }
  }
  return byKey.values.toList();
}

bool _has(Object? v) => v != null && v != '';

/// The web asks before sending when a required field is unanswered, or
/// when nothing is answered and nothing has a default.
bool chatVariablesNeeded(
  List<Map<String, dynamic>> fields,
  Map<String, dynamic> values,
) {
  if (fields.isEmpty) return false;
  final empty = fields.every(
    (f) => !_has(values[f['key']]) && !_has(f['default']),
  );
  final missing = fields.any(
    (f) =>
        f['required'] == true && !_has(values[f['key']]) && !_has(f['default']),
  );
  return empty || missing;
}

/// Answers back in the field's own type: numbers and switches as such.
Object? chatVariableValue(Map<String, dynamic> field, String text) =>
    switch (field['type']) {
      'checkbox' => text == 'true',
      'number' || 'range' => num.tryParse(text) ?? (text.isEmpty ? null : text),
      _ => text,
    };

/// The fields of the chat's model(s) right now.
List<Map<String, dynamic>> currentChatVariableFields(WidgetRef ref) {
  final state = ref.read(chatControllerProvider);
  return chatVariableFields(ref.read(modelsProvider).value ?? const [], [
    ?state.modelId,
    ...state.compareIds,
  ]);
}

/// Asks for this chat's variables and saves them. False if dismissed.
Future<bool> editChatVariables(BuildContext context, WidgetRef ref) async {
  final fields = currentChatVariableFields(ref);
  if (fields.isEmpty) return true;
  final values = ref.read(chatControllerProvider).variables;
  final answers = await showDialog<Map<String, String>>(
    context: context,
    builder: (_) => VariablesDialog(
      title: 'Chat Variables',
      action: 'Save',
      vars: [
        for (final f in fields)
          PromptVariable('${f['key']}', '${f['type']}', {
            ...f,
            'default': _has(values[f['key']]) ? values[f['key']] : f['default'],
          }),
      ],
    ),
  );
  if (answers == null) return false;
  try {
    await ref.read(chatControllerProvider.notifier).setVariables({
      for (final f in fields)
        '${f['key']}': chatVariableValue(f, answers['${f['key']}'] ?? ''),
    });
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save chat variables: $e')),
      );
    }
  }
  return true;
}
