import 'dart:async';

import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../core/theme.dart';
import 'studio_doc.dart';
import '../../core/widgets/markdown_style.dart';
import '../../core/i18n/app_strings.dart';

class AiResult {
  const AiResult(this.instruction, this.text);
  final String instruction;
  final String text;
}

/// Ask the AI for a change, watch it write, then keep it or not.
class AiSheet extends StatefulWidget {
  const AiSheet({
    super.key,
    required this.title,
    required this.suggestions,
    required this.run,
    this.dictate,
  });
  final String title;
  final List<String> suggestions;
  final Stream<String> Function(String instruction) run;

  /// Says the instruction instead of typing it.
  final Future<String?> Function(BuildContext context)? dictate;

  @override
  State<AiSheet> createState() => AiSheetState();
}

class AiSheetState extends State<AiSheet> {
  final _instruction = TextEditingController();
  StreamSubscription<String>? _sub;
  String? _text;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _go([String? suggestion]) {
    if (suggestion != null) _instruction.text = suggestion;
    final instruction = _instruction.text.trim();
    if (instruction.isEmpty) {
      setState(() => _error = 'Say what to change, or tap a suggestion');
      return;
    }
    FocusScope.of(context).unfocus();
    _sub?.cancel();
    setState(() {
      _text = '';
      _error = null;
      _done = false;
    });
    _sub = widget
        .run(instruction)
        .listen(
          (d) => setState(() => _text = (_text ?? '') + d),
          onError: (Object e) => setState(() {
            _error = '$e';
            _done = true;
          }),
          onDone: () => setState(() => _done = true),
          cancelOnError: true,
        );
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final writing = _text != null && !_done;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _instruction,
              autofocus: _text == null,
              minLines: 1,
              maxLines: 4,
              enabled: !writing,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _go(),
              decoration: InputDecoration(
                hintText: tr('What should change?'),
                border: const OutlineInputBorder(),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.dictate != null)
                      IconButton(
                        tooltip: tr('Say it'),
                        onPressed: writing
                            ? null
                            : () async {
                                final said = await widget.dictate!(context);
                                if (said == null || said.isEmpty || !mounted) {
                                  return;
                                }
                                _instruction.text = said;
                                _go();
                              },
                        icon: const Icon(Icons.mic_none),
                      ),
                    IconButton(
                      tooltip: tr('Apply'),
                      onPressed: writing ? null : _go,
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
            if (_text == null) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final s in widget.suggestions)
                    ActionChip(label: Text(s), onPressed: () => _go(s)),
                ],
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_text != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (writing) ...[
                    const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    writing ? 'Writing…' : 'The change',
                    style: TextStyle(color: muted),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Flexible(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: SingleChildScrollView(
                    reverse: writing,
                    child: MarkdownBlock(
                      data: cleanAiText(_text!),
                      config: nexusMarkdown(context),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const T('Discard'),
                  ),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: writing ? null : _go,
                    child: const T('Try again'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: writing || _text!.trim().isEmpty
                        ? null
                        : () => Navigator.pop(
                            context,
                            AiResult(_instruction.text.trim(), _text!),
                          ),
                    child: const T('Keep it'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
