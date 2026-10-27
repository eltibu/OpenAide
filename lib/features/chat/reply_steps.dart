import 'package:flutter/material.dart';

import 'reply_parts.dart';
import 'side_panel.dart';

/// A group of steps (thinking, tool calls, task steps) folded into one line,
/// like the Claude app: tap to see each step, tap a step to see its detail.
class ReplySteps extends StatefulWidget {
  const ReplySteps({
    super.key,
    required this.steps,
    this.live = false,
    this.open = false,
  });
  final List<StepPart> steps;

  /// Starts unfolded (Settings > Chats, "Always expand details").
  final bool open;

  /// The reply is still working on these steps.
  final bool live;

  @override
  State<ReplySteps> createState() => _ReplyStepsState();
}

class _ReplyStepsState extends State<ReplySteps> {
  late bool _open = widget.open;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final small = theme.textTheme.bodyMedium?.copyWith(color: muted);
    final working = widget.live && widget.steps.any((s) => !s.done);
    final title = working
        ? currentStep(widget.steps)
        : stepsSummary(widget.steps);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 18,
                    child: working
                        ? Padding(
                            padding: const EdgeInsets.all(2),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: muted,
                            ),
                          )
                        : Icon(
                            _groupIcon(widget.steps),
                            size: 18,
                            color: muted,
                          ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      title,
                      style: small,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Icons.chevron_right, size: 18, color: muted),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.only(left: 8, top: 2),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: theme.colorScheme.outlineVariant,
                            width: 1.5,
                          ),
                        ),
                      ),
                      padding: const EdgeInsets.only(left: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final s in widget.steps)
                            _Step(step: s, live: widget.live),
                        ],
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

IconData _groupIcon(List<StepPart> steps) {
  if (steps.any((s) => s is ToolPart)) return Icons.build_outlined;
  if (steps.any((s) => s is ThinkingPart)) return Icons.psychology_outlined;
  return Icons.checklist;
}

class _Step extends StatefulWidget {
  const _Step({required this.step, required this.live});
  final StepPart step;
  final bool live;

  @override
  State<_Step> createState() => _StepState();
}

class _StepState extends State<_Step> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final s = widget.step;
    final working = widget.live && !s.done;
    final failed = s is ToolPart && s.failed;
    final (IconData icon, String title) = switch (s) {
      ThinkingPart(:final seconds) => (
        Icons.psychology_outlined,
        working
            ? 'Thinking…'
            : seconds != null && seconds > 0
            ? 'Thought for ${seconds}s'
            : 'Thought',
      ),
      ToolPart(:final name) => (
        failed ? Icons.error_outline : Icons.build_outlined,
        working ? 'Using ${toolLabel(name)}…' : _capital(toolLabel(name)),
      ),
      StatusPart(:final description) => (
        Icons.check_circle_outline,
        description,
      ),
    };
    final hasDetail = switch (s) {
      ThinkingPart(:final text) => text.isNotEmpty,
      ToolPart() => true,
      StatusPart() => false,
    };
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.square(
            dimension: 16,
            child: working
                ? Padding(
                    padding: const EdgeInsets.all(2),
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: muted,
                    ),
                  )
                : Icon(icon, size: 16, color: failed ? scheme.error : muted),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.bodySmall?.copyWith(
                color: failed ? scheme.error : muted,
              ),
            ),
          ),
          if (hasDetail)
            Icon(
              _open ? Icons.expand_less : Icons.expand_more,
              size: 16,
              color: muted,
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasDetail)
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _open = !_open),
            child: row,
          )
        else
          row,
        if (_open && hasDetail)
          Padding(
            padding: const EdgeInsets.only(left: 24, bottom: 8),
            child: _detail(context, s),
          ),
      ],
    );
  }

  Widget _detail(BuildContext context, StepPart s) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final small = theme.textTheme.bodySmall?.copyWith(color: muted);
    final mono = small?.copyWith(fontFamily: 'monospace', fontSize: 12);
    Widget box(String label, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: small?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => showBeside(
                  context,
                  'step:${identityHashCode(s)}:$label',
                  (_) => _StepPage(
                    title:
                        '${_capital(toolLabel((s as ToolPart).name))}: '
                        '${label.toLowerCase()}',
                    text: label == 'Result'
                        ? prettyJson(s.result ?? '')
                        : prettyJson(s.arguments),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.open_in_new, size: 14, color: muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 320),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: SelectableText(text, style: mono),
            ),
          ),
        ],
      ),
    );
    return switch (s) {
      ThinkingPart(:final text) => SelectableText(
        text,
        style: small?.copyWith(height: 1.45),
      ),
      ToolPart(:final arguments, :final result) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (arguments.trim().isNotEmpty && arguments.trim() != '{}')
            box('Input', prettyJson(arguments)),
          if (result != null)
            box('Result', _clip(prettyJson(result)))
          else if (widget.live)
            Text('Waiting for the result…', style: small),
        ],
      ),
      StatusPart() => const SizedBox.shrink(),
    };
  }
}

String _clip(String text) =>
    text.length > 4000 ? '${text.substring(0, 4000)}…' : text;

String _capital(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// A tool's whole input or result, beside the chat or full screen.
class _StepPage extends StatelessWidget {
  const _StepPage({required this.title, required this.text});
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: panelLeading(context),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
      ),
    ),
  );
}
