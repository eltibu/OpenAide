/// Writing a tool (Workspace) or a function (Admin) in Python, as the web's
/// code editors: new from a starter, imported from a link, cloned, or the
/// code of one that exists.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// 'tool' or 'function'.
String _base(String kind) =>
    kind == 'tool' ? '/api/v1/tools' : '/api/v1/functions';

/// Ids must be Python names: lowercase letters, digits and _.
String codeIdFrom(String name) {
  final id = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  return RegExp(r'^[0-9]').hasMatch(id) ? '_$id' : id;
}

const toolStarter = '''import os
from datetime import datetime
from pydantic import BaseModel, Field


class Tools:
    def __init__(self):
        pass

    # Add your tools as methods with type hints and a docstring.

    def get_current_time(self) -> str:
        """
        Get the current date and time.
        """
        now = datetime.now()
        return now.strftime("%A, %B %d, %Y %I:%M %p")
''';

const functionStarter = '''from pydantic import BaseModel, Field
from typing import Optional


class Filter:
    class Valves(BaseModel):
        priority: int = Field(default=0, description="Order among filters.")

    def __init__(self):
        self.valves = self.Valves()

    def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        # Change the request before it reaches the model.
        return body

    def outlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        # Change the reply after the model answers.
        return body
''';

/// Asks for a link (a GitHub page works too), has the server fetch the
/// code, and opens it in a new editor. True when it was saved.
Future<bool> importCodeFromUrl(
  BuildContext context,
  WidgetRef ref,
  String kind,
) async {
  final url = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Import from URL'),
      content: TextField(
        controller: url,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          labelText: 'URL',
          hintText: 'https://github.com/…/tool.py',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(d, true),
          child: const Text('Import'),
        ),
      ],
    ),
  );
  if (ok != true || url.text.trim().isEmpty || !context.mounted) return false;
  try {
    final res = await ref
        .read(clientProvider)
        .send(
          'POST',
          '${_base(kind)}/load/url',
          body: {'url': url.text.trim()},
        );
    if (!context.mounted) return false;
    final loaded = (res as Map).cast<String, dynamic>();
    return await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => CodeItemEditor(
              kind: kind,
              start: {
                'name': '${loaded['name'] ?? ''}',
                'content': '${loaded['content'] ?? ''}',
              },
            ),
          ),
        ) ==
        true;
  } catch (e) {
    if (context.mounted) _say(context, '$e');
    return false;
  }
}

class CodeItemEditor extends ConsumerStatefulWidget {
  /// [id] edits one that exists; otherwise [start] fills a new one.
  const CodeItemEditor({super.key, required this.kind, this.id, this.start});
  final String kind;
  final String? id;
  final Map<String, dynamic>? start;

  @override
  ConsumerState<CodeItemEditor> createState() => _CodeItemEditorState();
}

class _CodeItemEditorState extends ConsumerState<CodeItemEditor> {
  final _name = TextEditingController();
  final _id = TextEditingController();
  final _description = TextEditingController();
  final _code = TextEditingController();
  Map<String, dynamic> _meta = {};
  bool _idEdited = false;
  bool _loading = false;
  bool _saving = false;
  Object? _error;

  bool get _isNew => widget.id == null;
  String get _noun => widget.kind == 'tool' ? 'Tool' : 'Function';

  @override
  void initState() {
    super.initState();
    if (_isNew) {
      _fill(widget.start ?? const {});
      if (_code.text.isEmpty) {
        _code.text = widget.kind == 'tool' ? toolStarter : functionStarter;
      }
      _id.text = codeIdFrom(_name.text);
    } else {
      _load();
    }
  }

  void _fill(Map<String, dynamic> item) {
    _meta = {...?(item['meta'] as Map?)?.cast<String, dynamic>()};
    _name.text = '${item['name'] ?? ''}';
    _description.text = '${_meta['description'] ?? ''}';
    _code.text = '${item['content'] ?? ''}';
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await ref
          .read(clientProvider)
          .send('GET', '${_base(widget.kind)}/id/${widget.id}');
      _fill((res as Map).cast<String, dynamic>());
      _id.text = widget.id!;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final id = _isNew ? codeIdFrom(_id.text) : widget.id!;
    if (name.isEmpty || id.isEmpty) return _say(context, 'Give it a name');
    if (_code.text.trim().isEmpty) return _say(context, 'The code is empty');
    setState(() => _saving = true);
    final description = _description.text.trim();
    try {
      await ref
          .read(clientProvider)
          .send(
            'POST',
            _isNew
                ? '${_base(widget.kind)}/create'
                : '${_base(widget.kind)}/id/$id/update',
            body: {
              'id': id,
              'name': name,
              'content': _code.text,
              'meta': {
                ..._meta,
                'description': description.isEmpty ? null : description,
              },
            },
          );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _say(context, '$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New $_noun' : 'Edit $_noun'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving || _loading || _error != null ? null : _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text("Couldn't load it.\n$_error"))
          : _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_saving) const LinearProgressIndicator(minHeight: 2),
                TextField(
                  controller: _name,
                  decoration: InputDecoration(labelText: '$_noun Name'),
                  onChanged: (v) {
                    if (_isNew && !_idEdited) {
                      setState(() => _id.text = codeIdFrom(v));
                    }
                  },
                ),
                TextField(
                  controller: _id,
                  enabled: _isNew,
                  decoration: InputDecoration(
                    labelText: '$_noun ID',
                    helperText: _isNew
                        ? 'Letters, digits and _ only. It can\'t change later.'
                        : null,
                  ),
                  onChanged: (_) => _idEdited = true,
                ),
                TextField(
                  controller: _description,
                  maxLines: null,
                  decoration: InputDecoration(labelText: '$_noun Description'),
                ),
                const SizedBox(height: 16),
                Text('Code', style: TextStyle(color: muted)),
                const SizedBox(height: 4),
                TextField(
                  controller: _code,
                  minLines: 16,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Only add code you trust: it runs on your server.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
    );
  }
}
