import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_screen.dart' show readingInset;

/// One message in the playground, any role, editable.
class _Turn {
  _Turn(this.role, [String text = ''])
    : text = TextEditingController(text: text);
  String role;
  final TextEditingController text;
}

/// The web's Playground: try a model on hand-written messages without making
/// a chat. Nothing here is saved.
class PlaygroundScreen extends ConsumerStatefulWidget {
  const PlaygroundScreen({super.key});

  @override
  ConsumerState<PlaygroundScreen> createState() => _PlaygroundScreenState();
}

class _PlaygroundScreenState extends ConsumerState<PlaygroundScreen> {
  String? _model;
  final _system = TextEditingController();
  final _turns = [_Turn('user')];
  final _temperature = TextEditingController();
  StreamSubscription<String>? _run;
  String? _error;

  bool get _running => _run != null;

  @override
  void dispose() {
    _run?.cancel();
    super.dispose();
  }

  void _start() {
    final model = _model;
    if (model == null) {
      setState(() => _error = 'Pick a model first');
      return;
    }
    final messages = [
      if (_system.text.trim().isNotEmpty)
        {'role': 'system', 'content': _system.text.trim()},
      for (final t in _turns)
        if (t.text.text.trim().isNotEmpty)
          {'role': t.role, 'content': t.text.text},
    ];
    if (messages.isEmpty) {
      setState(() => _error = 'Write a message first');
      return;
    }
    final temperature = double.tryParse(_temperature.text.trim());
    final reply = _Turn('assistant');
    setState(() {
      _error = null;
      _turns.add(reply);
    });
    _run = ref
        .read(clientProvider)
        .streamCompletion(
          model: model,
          messages: messages,
          extraParams: {'temperature': ?temperature},
        )
        .listen(
          (delta) => setState(() => reply.text.text += delta),
          onError: (Object e) => setState(() {
            _error = '$e';
            _run = null;
          }),
          onDone: () => setState(() {
            _run = null;
            // Ready for the next message.
            _turns.add(_Turn('user'));
          }),
          cancelOnError: true,
        );
  }

  void _stop() {
    _run?.cancel();
    setState(() => _run = null);
  }

  @override
  Widget build(BuildContext context) {
    final models = ref.watch(modelsProvider).value ?? const [];
    _model ??= models.isEmpty ? null : models.first.id;
    final muted = context.nexus.muted;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playground'),
        actions: [
          IconButton(
            tooltip: 'Clear',
            onPressed: _running
                ? null
                : () => setState(() {
                    _turns
                      ..clear()
                      ..add(_Turn('user'));
                    _error = null;
                  }),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _running ? _stop : _start,
        icon: Icon(_running ? Icons.stop : Icons.play_arrow),
        label: Text(_running ? 'Stop' : 'Run'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          readingInset(context, 16),
          8,
          readingInset(context, 16),
          96,
        ),
        children: [
          DropdownButtonFormField<String>(
            initialValue: _model,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Model'),
            items: [
              for (final m in models)
                DropdownMenuItem(
                  value: m.id,
                  child: Text(m.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: _running ? null : (v) => setState(() => _model = v),
          ),
          TextField(
            controller: _temperature,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Temperature',
              hintText: 'Model default',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _system,
            minLines: 2,
            maxLines: null,
            decoration: const InputDecoration(
              labelText: 'System',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          for (final (i, t) in _turns.indexed)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              elevation: 0,
              color: t.role == 'user'
                  ? context.nexus.userBubble
                  : scheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        TextButton(
                          // Tap to switch who said it, as on the web.
                          onPressed: _running
                              ? null
                              : () => setState(
                                  () => t.role = t.role == 'user'
                                      ? 'assistant'
                                      : 'user',
                                ),
                          child: Text(
                            t.role == 'user' ? 'USER' : 'ASSISTANT',
                            style: const TextStyle(letterSpacing: 1),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Remove',
                          visualDensity: VisualDensity.compact,
                          onPressed: _running
                              ? null
                              : () => setState(() => _turns.removeAt(i)),
                          icon: Icon(Icons.close, size: 18, color: muted),
                        ),
                      ],
                    ),
                    TextField(
                      controller: t.text,
                      maxLines: null,
                      decoration: InputDecoration.collapsed(
                        hintText: t.role == 'user'
                            ? 'Enter a user message'
                            : 'Enter an assistant message',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _running
                  ? null
                  : () => setState(
                      () => _turns.add(
                        _Turn(
                          _turns.isNotEmpty && _turns.last.role == 'user'
                              ? 'assistant'
                              : 'user',
                        ),
                      ),
                    ),
              icon: const Icon(Icons.add),
              label: const Text('Add message'),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
        ],
      ),
    );
  }
}
