/// The rest of the web UI's chat menu: share a link, export, clone and tags.
/// All of it is kept on the server, as on the web.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../studio/studio_export.dart' show pdfTheme, toPdf;
import 'chat_controller.dart';

/// The chat's own messages as text, oldest first, as the web's .txt export.
String chatAsText(Chat chat) =>
    [for (final m in chat.thread) '### ${m.role.toUpperCase()}\n${m.content}']
        .join('\n\n');

/// The same, as Markdown with who said what, for the PDF.
String chatAsMarkdown(Chat chat) => [
  for (final m in chat.thread)
    '${m.role == 'user' ? '**You**' : '**${m.model ?? 'Nexus'}**'}\n\n'
        '${m.content}',
].join('\n\n---\n\n');

/// A file name made from the chat's title.
String chatFileName(String title, String ext) {
  final base = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\n\r]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
  return '${base.isEmpty ? 'chat' : base}.$ext';
}

/// Saves chat [id] as JSON (what the web exports, and imports again), plain
/// text or PDF, to where the person picks.
Future<void> exportChat(
  BuildContext context,
  WidgetRef ref,
  String id,
  String kind,
) async {
  final client = ref.read(clientProvider);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final raw = (await client.send('GET', '/api/v1/chats/$id') as Map)
        .cast<String, dynamic>();
    final chat = Chat.fromServer(raw);
    final (Uint8List bytes, String type) = switch (kind) {
      'json' => (
        Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert([raw])),
        ),
        'application/json',
      ),
      'pdf' => (
        await toPdf(
          chat.title,
          chatAsMarkdown(chat),
          theme: await pdfTheme(rootBundle.load),
        ),
        'application/pdf',
      ),
      _ => (Uint8List.fromList(utf8.encode(chatAsText(chat))), 'text/plain'),
    };
    final name = chatFileName(
      chat.title,
      kind == 'json'
          ? 'json'
          : kind == 'pdf'
          ? 'pdf'
          : 'txt',
    );
    final saved = await FilePicker.saveFile(
      fileName: name,
      bytes: bytes,
      mimeType: type,
    );
    if (saved != null) {
      messenger.showSnackBar(SnackBar(content: Text('Saved $name')));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text("Couldn't export: $e")));
  }
}

/// The title in the server's reply to a title task, or null.
String? titleFromTask(Object? res) {
  final text =
      ((((res as Map?)?['choices'] as List?)?.firstOrNull as Map?)?['message']
              as Map?)?['content']
          as String? ??
      '';
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start == -1 || end <= start) return null;
  try {
    final parsed = jsonDecode(
      text.substring(start, end + 1).replaceAll(RegExp('[\'‘’`]'), '"'),
    );
    final title = parsed is Map ? parsed['title'] : null;
    return title is String && title.trim().isNotEmpty ? title.trim() : null;
  } on FormatException {
    return null;
  }
}

/// A new title for chat [id] from its messages, as the web's Generate.
Future<String?> generateChatTitle(OpenWebUiClient client, String id) async {
  final chat = await client.chat(id);
  final thread = chat.thread;
  final model =
      thread.reversed
          .where((m) => m.role == 'assistant' && m.model != null)
          .firstOrNull
          ?.model ??
      chat.models.firstOrNull;
  if (model == null) return null;
  final res = await client.send(
    'POST',
    '/api/v1/tasks/title/completions',
    body: {
      'model': model,
      'messages': [
        for (final m in thread) {'role': m.role, 'content': m.content},
      ],
      'chat_id': id,
    },
  );
  return titleFromTask(res);
}

/// A copy of chat [id] ("Clone of …"), opened.
Future<void> cloneChat(WidgetRef ref, String id, String title) async {
  final res = await ref
      .read(clientProvider)
      .send(
        'POST',
        '/api/v1/chats/$id/clone',
        body: {'title': 'Clone of $title'},
      );
  refreshChatLists(ref.invalidate);
  final newId = (res as Map?)?['id'];
  if (newId is String) {
    await ref.read(chatControllerProvider.notifier).open(newId);
  }
}

/// Shows and changes chat [id]'s tags.
Future<void> editTags(BuildContext context, String id) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _TagsSheet(id: id),
    );

class _TagsSheet extends ConsumerStatefulWidget {
  const _TagsSheet({required this.id});
  final String id;

  @override
  ConsumerState<_TagsSheet> createState() => _TagsSheetState();
}

class _TagsSheetState extends ConsumerState<_TagsSheet> {
  late final OpenWebUiClient _client = ref.read(clientProvider);
  final _text = TextEditingController();
  List<String>? _tags;
  List<String> _all = const [];
  String? _error;

  String get _base => '/api/v1/chats/${widget.id}/tags';

  static List<String> _names(Object? res) => [
    for (final t in (res as List? ?? const []).whereType<Map>())
      '${t['name'] ?? t['id']}',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final mine = _names(await _client.send('GET', _base));
      final all = _names(await _client.send('GET', '/api/v1/chats/all/tags'));
      if (mounted) {
        setState(() {
          _tags = mine;
          _all = all;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _change(String method, String name) async {
    final tag = name.trim();
    if (tag.isEmpty) return;
    try {
      final res = await _client.send(method, _base, body: {'name': tag});
      _text.clear();
      refreshChatLists(ref.invalidate);
      if (mounted) setState(() => _tags = _names(res));
      if (!_all.contains(tag)) _all = [..._all, tag];
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tags = _tags;
    final q = _text.text.trim().toLowerCase();
    final suggestions = [
      for (final t in _all)
        if (!(tags ?? const []).contains(t) &&
            (q.isEmpty || t.toLowerCase().contains(q)))
          t,
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tags', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (tags == null && _error == null)
              const LinearProgressIndicator()
            else if (tags != null)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (tags.isEmpty) const Text('No tags yet.'),
                  for (final t in tags)
                    InputChip(
                      label: Text(t),
                      onDeleted: () => _change('DELETE', t),
                    ),
                ],
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              decoration: InputDecoration(
                hintText: 'Add a tag',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: 'Add',
                  icon: const Icon(Icons.add),
                  onPressed: () => _change('POST', _text.text),
                ),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (v) => _change('POST', v),
            ),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final t in suggestions.take(12))
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 16),
                      label: Text(t),
                      onPressed: () => _change('POST', t),
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

/// Who can open a shared link, as the web's sharing choices.
enum ShareAudience { onlyMe, everyone, anyone }

/// The grants the web sends for [audience]: signed-in users ('user' '*')
/// or anyone with the link ('anyone' '*').
List<Map<String, String>> shareGrants(ShareAudience audience) =>
    switch (audience) {
      ShareAudience.onlyMe => const [],
      ShareAudience.everyone => const [
        {'principal_type': 'user', 'principal_id': '*', 'permission': 'read'},
      ],
      ShareAudience.anyone => const [
        {'principal_type': 'anyone', 'principal_id': '*', 'permission': 'read'},
      ],
    };

ShareAudience audienceOf(List<Map> grants) {
  bool has(String type) => grants.any(
    (g) =>
        g['principal_type'] == type &&
        g['principal_id'] == '*' &&
        g['permission'] == 'read',
  );
  if (has('anyone')) return ShareAudience.anyone;
  if (has('user')) return ShareAudience.everyone;
  return ShareAudience.onlyMe;
}

/// Makes, copies and removes a link to chat [id], and sets who can open it.
Future<void> shareChat(BuildContext context, String id) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _ShareSheet(id: id),
    );

class _ShareSheet extends ConsumerStatefulWidget {
  const _ShareSheet({required this.id});
  final String id;

  @override
  ConsumerState<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<_ShareSheet> {
  late final OpenWebUiClient _client = ref.read(clientProvider);
  bool _loading = true;
  bool _busy = false;
  String? _shareId;
  ShareAudience _audience = ShareAudience.onlyMe;
  bool _replies = false;
  String? _error;

  String get _link => '${_client.baseUrl}/s/$_shareId';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final chat = await _client.send('GET', '/api/v1/chats/${widget.id}');
      _shareId = (chat as Map)['share_id'] as String?;
      if (_shareId != null) {
        final grants = await _client.send(
          'GET',
          '/api/v1/chats/shared/${widget.id}/access',
        );
        _audience = audienceOf(
          [
            ...((grants is Map ? grants['access_grants'] : grants) as List? ??
                const []),
          ].whereType<Map>().toList(),
        );
        try {
          final shared = await _client.send(
            'GET',
            '/api/v1/chats/share/$_shareId',
          );
          _replies =
              ((shared as Map?)?['chat'] as Map?)?['share_mode'] == 'continue';
        } catch (_) {}
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _create() => _run(() async {
    final res = await _client.send('POST', '/api/v1/chats/${widget.id}/share');
    _shareId = (res as Map)['share_id'] as String?;
  });

  Future<void> _save(ShareAudience audience, bool replies) => _run(() async {
    if (_shareId == null) {
      final res = await _client.send(
        'POST',
        '/api/v1/chats/${widget.id}/share',
      );
      _shareId = (res as Map)['share_id'] as String?;
    }
    await _client.send(
      'POST',
      '/api/v1/chats/shared/${widget.id}/access/update',
      body: {
        'access_grants': shareGrants(audience),
        'share_mode': replies ? 'continue' : null,
      },
    );
    _audience = audience;
    _replies = replies;
  });

  Future<void> _delete() => _run(() async {
    await _client.send('DELETE', '/api/v1/chats/${widget.id}/share');
    _shareId = null;
    _audience = ShareAudience.onlyMe;
    _replies = false;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Share chat', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            if (_loading)
              const LinearProgressIndicator()
            else ...[
              Text(
                _shareId == null
                    ? 'Make a link to a copy of this chat as it is now. Later '
                          'messages are not in it until you update the link.'
                    : 'The link shows this chat as it was when it was made.',
                style: TextStyle(color: muted),
              ),
              if (_shareId != null) ...[
                const SizedBox(height: 12),
                SelectableText(_link),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy link'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _link));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Link copied')),
                        );
                      },
                    ),
                    OutlinedButton(
                      onPressed: _busy ? null : _create,
                      child: const Text('Update link'),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _delete,
                      child: const Text('Delete link'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Text('Who can open it', style: theme.textTheme.titleSmall),
              RadioGroup<ShareAudience>(
                groupValue: _audience,
                onChanged: (a) {
                  if (a != null && !_busy) _save(a, _replies);
                },
                child: const Column(
                  children: [
                    RadioListTile(
                      contentPadding: EdgeInsets.zero,
                      value: ShareAudience.onlyMe,
                      title: Text('Only me'),
                    ),
                    RadioListTile(
                      contentPadding: EdgeInsets.zero,
                      value: ShareAudience.everyone,
                      title: Text('Everyone signed in to the server'),
                    ),
                    RadioListTile(
                      contentPadding: EdgeInsets.zero,
                      value: ShareAudience.anyone,
                      title: Text('Anyone with the link'),
                    ),
                  ],
                ),
              ),
              if (_audience != ShareAudience.onlyMe)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow replies'),
                  subtitle: const Text(
                    'People can carry on the chat, not just copy it',
                  ),
                  value: _replies,
                  onChanged: _busy ? null : (v) => _save(_audience, v),
                ),
              if (_shareId == null)
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _busy ? null : _create,
                    child: const Text('Create link'),
                  ),
                ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}
