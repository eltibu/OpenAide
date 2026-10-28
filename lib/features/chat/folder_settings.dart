/// A folder's settings, as the web's Edit Folder window: its name, a system
/// prompt and knowledge every chat in it uses. The server applies them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../workspace/knowledge_screen.dart' show knowledgeListProvider;
import 'chat_controller.dart';

Future<void> editFolder(BuildContext context, String id) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _FolderSettings(id: id),
    );

class _FolderSettings extends ConsumerStatefulWidget {
  const _FolderSettings({required this.id});
  final String id;

  @override
  ConsumerState<_FolderSettings> createState() => _FolderSettingsState();
}

class _FolderSettingsState extends ConsumerState<_FolderSettings> {
  final _name = TextEditingController();
  final _system = TextEditingController();
  Map<String, dynamic> _data = {};
  List<Map<String, dynamic>> _files = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _system.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final f =
          (await ref
                      .read(clientProvider)
                      .send('GET', '/api/v1/folders/${widget.id}')
                  as Map)
              .cast<String, dynamic>();
      _name.text = '${f['name'] ?? ''}';
      _data = ((f['data'] as Map?) ?? const {}).cast<String, dynamic>();
      _system.text = '${_data['system_prompt'] ?? ''}';
      _files = [
        for (final x in (_data['files'] as List? ?? const []).whereType<Map>())
          x.cast<String, dynamic>(),
      ];
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(clientProvider)
          .send(
            'POST',
            '/api/v1/folders/${widget.id}/update',
            body: {
              if (_name.text.trim().isNotEmpty) 'name': _name.text.trim(),
              'data': {
                ..._data,
                'system_prompt': _system.text.trim(),
                'files': _files,
              },
            },
          );
      refreshChatLists(ref.invalidate);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = "Couldn't save: $e";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final knowledge = ref.watch(knowledgeListProvider).value ?? const [];
    final picked = {for (final f in _files) f['id']};
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: EdgeInsets.fromLTRB(
                  20,
                  0,
                  20,
                  16 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                children: [
                  Text('Folder settings', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'Every chat in this folder uses these.',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _system,
                    minLines: 3,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText: 'System prompt',
                      hintText: 'How OpenAide should act in these chats',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Knowledge', style: theme.textTheme.titleSmall),
                  if (knowledge.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('No knowledge bases on the server yet.'),
                    ),
                  for (final k in knowledge)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(k.name),
                      subtitle: k.description.isEmpty
                          ? null
                          : Text(
                              k.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      value: picked.contains(k.id),
                      onChanged: (on) => setState(() {
                        _files.removeWhere((f) => f['id'] == k.id);
                        if (on ?? false) {
                          _files.add({
                            'type': 'collection',
                            'id': k.id,
                            'name': k.name,
                            'description': k.description,
                          });
                        }
                      }),
                    ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
