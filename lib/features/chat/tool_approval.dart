/// A reply that stopped to wait on the person: a tool it wants to use
/// (when Tool Permissions are set to ask) or questions the model asked with
/// `ask_user`. Same cards and the same server calls as the web UI.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/chat.dart';
import 'chat_controller.dart';

/// One question from `ask_user`.
class AskQuestion {
  const AskQuestion({
    required this.id,
    required this.header,
    required this.question,
    required this.options,
    required this.allowOther,
  });
  final String id;
  final String header;
  final String question;
  final List<({String label, String description})> options;
  final bool allowOther;
}

/// The tool call a reply is waiting on.
class PendingCall {
  const PendingCall({
    required this.callId,
    required this.name,
    required this.arguments,
  });
  final String callId;
  final String name;
  final Map<String, dynamic> arguments;

  bool get asksUser => name == 'ask_user';

  List<AskQuestion> get questions {
    final everyone = arguments['allow_other'] != false;
    return [
      for (final (i, q)
          in (arguments['questions'] as List? ?? const [])
              .whereType<Map>()
              .indexed)
        AskQuestion(
          id: '${q['id'] ?? 'q$i'}',
          header: '${q['header'] ?? ''}'.trim(),
          question: '${q['question'] ?? ''}'.trim(),
          options: [
            for (final o
                in (q['options'] as List? ?? const []).whereType<Map>())
              (
                label: '${o['label'] ?? ''}',
                description: '${o['description'] ?? ''}'.trim(),
              ),
          ],
          allowOther: q['allow_other'] is bool
              ? q['allow_other'] as bool
              : everyone,
        ),
    ];
  }
}

/// Arguments arrive as JSON text, sometimes encoded twice.
Map<String, dynamic> _arguments(Object? raw) {
  var value = raw;
  while (value is String) {
    try {
      value = jsonDecode(value);
    } catch (_) {
      break;
    }
  }
  return value is Map ? value.cast<String, dynamic>() : const {};
}

/// The call [m] is waiting on, if it is paused for the person.
PendingCall? pendingCall(ChatMessage m) {
  if (m.role != 'assistant' || m.done) return null;
  final output = m.extra['output'];
  if (output is! List) return null;
  final answered = {
    for (final item in output.whereType<Map>())
      if (item['type'] == 'function_call_output') '${item['call_id']}',
  };
  for (final item in output.whereType<Map>()) {
    final id = item['call_id'] ?? item['id'];
    if (item['type'] != 'function_call' || id == null) continue;
    if (answered.contains('$id')) continue;
    if (const {'pending', 'requires_approval'}.contains(item['status'])) {
      return PendingCall(
        callId: '$id',
        name: '${item['name'] ?? 'tool'}',
        arguments: _arguments(item['arguments']),
      );
    }
  }
  return null;
}

/// The card under a paused reply.
class PendingCallCard extends ConsumerWidget {
  const PendingCallCard({super.key, required this.reply, required this.call});
  final ChatMessage reply;
  final PendingCall call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(chatControllerProvider.notifier);
    if (call.asksUser && call.questions.isNotEmpty) {
      return _AskUserCard(
        key: ValueKey(call.callId),
        questions: call.questions,
        onAnswer: (answers) => controller.resolveTool(
          reply,
          call.callId,
          'answer',
          answers: answers,
        ),
        onSkip: () => controller.resolveTool(reply, call.callId, 'reject'),
      );
    }
    return _ApprovalCard(
      call: call,
      onAllow: () => controller.resolveTool(reply, call.callId, 'approve'),
      onDeny: () => controller.resolveTool(reply, call.callId, 'reject'),
    );
  }
}

Widget _frame(BuildContext context, Widget child) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      border: Border.all(color: scheme.outlineVariant),
      borderRadius: BorderRadius.circular(14),
    ),
    child: child,
  );
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({
    required this.call,
    required this.onAllow,
    required this.onDeny,
  });
  final PendingCall call;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final args = call.arguments.isEmpty
        ? ''
        : const JsonEncoder.withIndent('  ').convert(call.arguments);
    return _frame(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.build_outlined, size: 18, color: theme.hintColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'Allow '),
                      TextSpan(
                        text: call.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const TextSpan(text: ' to run?'),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (args.isNotEmpty)
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: Text('Details', style: theme.textTheme.labelMedium),
                children: [
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 240),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        args,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onDeny, child: const Text('Deny')),
              const SizedBox(width: 8),
              FilledButton(onPressed: onAllow, child: const Text('Allow')),
            ],
          ),
        ],
      ),
    );
  }
}

/// The model's questions, one at a time, as the web UI asks them.
class _AskUserCard extends StatefulWidget {
  const _AskUserCard({
    super.key,
    required this.questions,
    required this.onAnswer,
    required this.onSkip,
  });
  final List<AskQuestion> questions;
  final void Function(Map<String, dynamic> answers) onAnswer;
  final VoidCallback onSkip;

  @override
  State<_AskUserCard> createState() => _AskUserCardState();
}

class _AskUserCardState extends State<_AskUserCard> {
  final _answers = <String, Map<String, dynamic>>{};
  final _other = TextEditingController();
  int _at = 0;

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  void _next(Map<String, dynamic> answer) {
    final q = widget.questions[_at];
    _answers[q.id] = answer;
    if (_at < widget.questions.length - 1) {
      setState(() {
        _at++;
        final saved = _answers[widget.questions[_at].id];
        _other.text = saved?['type'] == 'other' ? '${saved!['text']}' : '';
      });
    } else {
      widget.onAnswer(Map.of(_answers));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = widget.questions[_at];
    final chosen = _answers[q.id];
    return _frame(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.help_outline,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  q.header.isEmpty ? 'Nexus has a question' : q.header,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              if (widget.questions.length > 1)
                Text(
                  '${_at + 1} of ${widget.questions.length}',
                  style: theme.textTheme.labelSmall,
                ),
            ],
          ),
          if (q.question.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text(q.question, style: theme.textTheme.bodyLarge),
            ),
          for (final (i, o) in q.options.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  backgroundColor: chosen?['option_index'] == i
                      ? theme.colorScheme.primaryContainer
                      : null,
                ),
                onPressed: () => _next({
                  'type': 'option',
                  'option_index': i,
                  'label': o.label,
                  'description': o.description,
                }),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(o.label),
                    if (o.description.isNotEmpty)
                      Text(
                        o.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (q.allowOther)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: _other,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  hintText: 'Something else…',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Answer',
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: _sendOther,
                  ),
                ),
                onSubmitted: (_) => _sendOther(),
              ),
            ),
          Row(
            children: [
              if (_at > 0)
                TextButton(
                  onPressed: () => setState(() => _at--),
                  child: const Text('Back'),
                ),
              const Spacer(),
              TextButton(onPressed: widget.onSkip, child: const Text('Skip')),
            ],
          ),
        ],
      ),
    );
  }

  void _sendOther() {
    final text = _other.text.trim();
    if (text.isEmpty) return;
    _other.clear();
    _next({'type': 'other', 'text': text});
  }
}
