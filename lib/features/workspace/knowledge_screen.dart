import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import 'knowledge_api.dart';

final knowledgeApiProvider = Provider<KnowledgeApi>(
  (ref) => KnowledgeApi(ref.watch(clientProvider)),
);

final knowledgeListProvider = FutureProvider<List<Knowledge>>(
  (ref) => ref.watch(knowledgeApiProvider).list(),
);

Future<(String, String)?> _askNameAndDescription(
  BuildContext context,
  String title, {
  String name = '',
  String description = '',
}) async {
  final n = TextEditingController(text: name);
  final d = TextEditingController(text: description);
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: n,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          TextField(
            controller: d,
            maxLines: null,
            decoration: const InputDecoration(labelText: 'What it\'s about'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (ok != true || n.text.trim().isEmpty) return null;
  return (n.text.trim(), d.text.trim());
}

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// Knowledge bases: collections of documents models can search.
class KnowledgeScreen extends ConsumerWidget {
  const KnowledgeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(knowledgeListProvider);
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(title: const Text('Knowledge')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New knowledge base',
        onPressed: () async {
          final v = await _askNameAndDescription(context, 'New knowledge base');
          if (v == null) return;
          try {
            final k = await ref.read(knowledgeApiProvider).create(v.$1, v.$2);
            ref.invalidate(knowledgeListProvider);
            if (context.mounted) {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => KnowledgeDetail(knowledge: k),
                ),
              );
            }
          } catch (e) {
            if (context.mounted) _say(context, '$e');
          }
        },
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(knowledgeListProvider.future),
        child: list.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load knowledge.\n$e'),
              ),
            ],
          ),
          data: (items) => ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No knowledge bases yet',
                    style: TextStyle(color: muted),
                  ),
                ),
              for (final k in items)
                ListTile(
                  leading: const Icon(Icons.menu_book_outlined),
                  title: Text(k.name),
                  subtitle: k.description.isEmpty
                      ? null
                      : Text(
                          k.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: muted),
                        ),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => KnowledgeDetail(knowledge: k),
                      ),
                    );
                    ref.invalidate(knowledgeListProvider);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class KnowledgeDetail extends ConsumerStatefulWidget {
  const KnowledgeDetail({super.key, required this.knowledge});
  final Knowledge knowledge;

  @override
  ConsumerState<KnowledgeDetail> createState() => _KnowledgeDetailState();
}

class _KnowledgeDetailState extends ConsumerState<KnowledgeDetail> {
  late final KnowledgeApi _api = ref.read(knowledgeApiProvider);
  late Knowledge _k = widget.knowledge;
  KnowledgeListing? _listing;
  String? _folder;
  Object? _error;
  final Set<String> _uploading = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _listing = await _api.files(_k.id, folderId: _folder);
      _error = null;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  void _open(String? folder) {
    setState(() {
      _folder = folder;
      _listing = null;
    });
    _load();
  }

  Future<void> _add() async {
    final picked = await FilePicker.pickFiles();
    for (final f in picked) {
      setState(() => _uploading.add(f.name));
      try {
        await _api.addFile(
          _k.id,
          await f.readAsBytes(),
          f.name,
          folderId: _folder,
        );
      } catch (e) {
        if (mounted) _say(context, '${f.name}: $e');
      }
      setState(() => _uploading.remove(f.name));
      await _load();
    }
  }

  Future<void> _remove(KnowledgeFile f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Remove ${f.name}?'),
        content: const Text('Models won\'t find it here any more.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.removeFile(_k.id, f.id);
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    _load();
  }

  Future<void> _menu(String action) async {
    if (action == 'edit') {
      final v = await _askNameAndDescription(
        context,
        'Edit knowledge base',
        name: _k.name,
        description: _k.description,
      );
      if (v == null) return;
      try {
        await _api.update(_k.id, v.$1, v.$2);
        setState(
          () => _k = Knowledge(
            id: _k.id,
            name: v.$1,
            description: v.$2,
            updated: DateTime.now(),
          ),
        );
      } catch (e) {
        if (mounted) _say(context, '$e');
      }
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text('Delete ${_k.name}?'),
          content: const Text(
            'Its documents are removed from it. This can\'t be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await _api.delete(_k.id);
        if (mounted) Navigator.pop(context);
      } catch (e) {
        if (mounted) _say(context, '$e');
      }
    }
  }

  String _size(int? b) {
    if (b == null) return '';
    if (b < 1024) return '$b B';
    if (b < 1 << 20) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final l = _listing;
    return PopScope(
      canPop: _folder == null,
      onPopInvokedWithResult: (popped, _) {
        if (popped) return;
        final path = l?.path ?? const [];
        _open(path.length > 1 ? path[path.length - 2].id : null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_k.name),
          actions: [
            if (_k.writable)
              PopupMenuButton<String>(
                onSelected: _menu,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
          ],
        ),
        floatingActionButton: _k.writable
            ? FloatingActionButton.extended(
                onPressed: _add,
                icon: const Icon(Icons.upload_file),
                label: const Text('Add files'),
              )
            : null,
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              if (_k.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Text(_k.description, style: TextStyle(color: muted)),
                ),
              if (l != null && (l.path.isNotEmpty || _folder != null))
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: () => _open(null),
                        child: const Text('All'),
                      ),
                      for (final f in l.path) ...[
                        Icon(Icons.chevron_right, size: 16, color: muted),
                        TextButton(
                          onPressed: () => _open(f.id),
                          child: Text(f.name),
                        ),
                      ],
                    ],
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Couldn\'t load files.\n$_error'),
                )
              else if (l == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (l.files.isEmpty &&
                  l.folders.isEmpty &&
                  _uploading.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No documents yet. Add files for models to search.',
                    style: TextStyle(color: muted),
                  ),
                ),
              for (final name in _uploading)
                ListTile(
                  leading: const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: Text(name),
                  subtitle: const Text('Uploading and reading…'),
                ),
              for (final f in l?.folders ?? const <KnowledgeFolder>[])
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(f.name),
                  onTap: () => _open(f.id),
                ),
              for (final f in l?.files ?? const <KnowledgeFile>[])
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(
                    f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      _size(f.size),
                      if (f.status == 'failed') 'Couldn\'t be read',
                      if (f.status == 'pending') 'Being read…',
                    ].where((s) => s.isNotEmpty).join(' · '),
                    style: TextStyle(
                      color: f.status == 'failed'
                          ? Theme.of(context).colorScheme.error
                          : muted,
                    ),
                  ),
                  trailing: _k.writable
                      ? IconButton(
                          tooltip: 'Remove',
                          onPressed: () => _remove(f),
                          icon: const Icon(Icons.close),
                        )
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
