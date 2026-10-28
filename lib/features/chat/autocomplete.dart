/// Settings > Interface > Prompt autocompletion: as you pause typing, the
/// model suggests how the message could go on, as the web's grey text.
/// On the phone the suggestion shows above the box; a tap adds it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import 'chat_controller.dart';

/// The text from the server's answer, which may wrap it as {"text": ...}.
String autoCompletionText(String response) {
  final start = response.indexOf('{');
  final end = response.lastIndexOf('}');
  if (start != -1 && end > start) {
    try {
      final parsed = jsonDecode(response.substring(start, end + 1));
      return parsed is Map && parsed['text'] is String
          ? parsed['text'] as String
          : '';
    } on FormatException {
      return '';
    }
  }
  return response;
}

/// Whether the person and the server both have it on.
bool autocompleteOn(WidgetRef ref) {
  final ui = ref.watch(userSettingsProvider).value?['ui'] as Map?;
  final features = ref.watch(serverConfigProvider).value?['features'] as Map?;
  return ui?['promptAutocomplete'] == true &&
      features?['enable_autocomplete_generation'] == true;
}

/// Watches [controller] and offers a continuation after a pause.
class AutocompleteBar extends ConsumerStatefulWidget {
  const AutocompleteBar({super.key, required this.controller});
  final TextEditingController controller;

  @override
  ConsumerState<AutocompleteBar> createState() => _AutocompleteBarState();
}

class _AutocompleteBarState extends ConsumerState<AutocompleteBar> {
  Timer? _wait;
  String? _for;
  String? _suggestion;
  int _asked = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _wait?.cancel();
    super.dispose();
  }

  void _changed() {
    final text = widget.controller.text;
    if (text == _for) return;
    _wait?.cancel();
    if (_suggestion != null) setState(() => _suggestion = null);
    // Commands and mentions have their own suggestions.
    if (text.trim().length < 3 || RegExp(r'(^/|[@#:]\S*$)').hasMatch(text)) {
      return;
    }
    _wait = Timer(const Duration(milliseconds: 900), () => _ask(text));
  }

  Future<void> _ask(String text) async {
    final state = ref.read(chatControllerProvider);
    final model = state.modelId;
    if (model == null) return;
    final ask = ++_asked;
    try {
      final res = await ref
          .read(clientProvider)
          .send(
            'POST',
            '/api/v1/tasks/auto/completions',
            body: {
              'model': model,
              'prompt': text,
              'messages': [
                for (final m in state.chat?.thread ?? const [])
                  {'role': m.role, 'content': m.content},
              ],
              'type': 'general',
              'stream': false,
              if (state.chat?.id.isNotEmpty ?? false) 'chat_id': state.chat!.id,
            },
          );
      final content =
          '${(((res as Map)['choices'] as List?)?.firstOrNull as Map?)?['message']?['content'] ?? ''}';
      final more = autoCompletionText(content);
      if (!mounted || ask != _asked || widget.controller.text != text) return;
      setState(() {
        _for = text;
        _suggestion = more.trim().isEmpty ? null : more;
      });
    } catch (_) {
      // No suggestion this time.
    }
  }

  void _accept() {
    final text = widget.controller.text;
    final more = _suggestion!;
    final joined = text.endsWith(' ') || more.startsWith(' ')
        ? '$text$more'
        : '$text $more';
    _for = null;
    widget.controller.value = TextEditingValue(
      text: joined,
      selection: TextSelection.collapsed(offset: joined.length),
    );
    setState(() => _suggestion = null);
  }

  @override
  Widget build(BuildContext context) {
    final s = _suggestion;
    if (s == null || widget.controller.text != _for) {
      return const SizedBox.shrink();
    }
    final muted = context.nexus.muted;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _accept,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, size: 16, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '…$s',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: muted),
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => setState(() => _suggestion = null),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
