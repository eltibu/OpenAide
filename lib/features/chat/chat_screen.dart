import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../update/update_screen.dart';
import 'chat_controller.dart';

class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatControllerProvider);
    final models = ref.watch(modelsProvider);

    // Default to the first server model once the list arrives.
    if (state.modelId == null && (models.value?.isNotEmpty ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => ref
            .read(chatControllerProvider.notifier)
            .selectModel(models.value!.first.id),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: models.when(
          data: (list) => list.isEmpty
              ? const Text('No models on server')
              : DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: list.any((m) => m.id == state.modelId)
                        ? state.modelId
                        : null,
                    hint: const Text('Choose a model'),
                    items: [
                      for (final m in list)
                        DropdownMenuItem(
                          value: m.id,
                          child: Text(m.name, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (id) {
                      if (id != null) {
                        ref
                            .read(chatControllerProvider.notifier)
                            .selectModel(id);
                      }
                    },
                  ),
                ),
          loading: () => const Text('Loading models…'),
          error: (e, _) => const Text('Models unavailable'),
        ),
        actions: [
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.edit_square),
            onPressed: () =>
                ref.read(chatControllerProvider.notifier).newChat(),
          ),
        ],
      ),
      drawer: const _ChatDrawer(),
      body: Column(
        children: [
          const UpdateBanner(),
          if (state.error != null)
            MaterialBanner(
              content: Text(state.error!),
              actions: [
                TextButton(
                  onPressed: () =>
                      ref.read(chatControllerProvider.notifier).retry(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          Expanded(
            child: state.loading
                ? const Center(child: CircularProgressIndicator())
                : state.messages.isEmpty
                ? const _EmptyState()
                : _MessageList(
                    messages: state.messages,
                    streaming: state.streaming,
                    status: state.status,
                  ),
          ),
          _Composer(streaming: state.streaming),
        ],
      ),
    );
  }
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(sessionProvider).value?.userName ?? '';
    return Center(
      child: Text(
        name.isEmpty ? 'How can I help?' : 'Hi $name, how can I help?',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
    );
  }
}

class _MessageList extends ConsumerWidget {
  const _MessageList({
    required this.messages,
    required this.streaming,
    this.status,
  });
  final List<ChatMessage> messages;
  final bool streaming;
  final String? status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mdConfig = dark
        ? MarkdownConfig.darkConfig
        : MarkdownConfig.defaultConfig;
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final m = messages[messages.length - 1 - i];
        final live = streaming && i == 0;
        if (m.role == 'user') {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.8,
                ),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: SelectableText(m.content),
              ),
              if (!streaming) _MessageActions(message: m),
            ],
          );
        }
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (m.content.isNotEmpty)
                MarkdownBlock(data: m.content, config: mdConfig)
              else if (live)
                Row(
                  children: [
                    const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    if (status != null && status!.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          status!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ],
                )
              else
                Text(
                  m.error ?? 'No reply. Tap Retry above to ask again.',
                  style: TextStyle(color: scheme.error),
                ),
              if (!live && !streaming) _MessageActions(message: m),
            ],
          ),
        );
      },
    );
  }
}

/// Copy, edit or regenerate, and switching between versions of a message.
class _MessageActions extends ConsumerWidget {
  const _MessageActions({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(chatControllerProvider.notifier);
    final chat = ref.watch(chatControllerProvider).chat;
    final siblings = chat?.siblingsOf(message) ?? const <String>[];
    final index = siblings.indexOf(message.id);
    final isUser = message.role == 'user';
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    Widget action(IconData icon, String tip, VoidCallback? onTap) => IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      color: muted,
      onPressed: onTap,
      icon: Icon(icon),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (siblings.length > 1) ...[
          action(
            Icons.chevron_left,
            'Previous version',
            index > 0 ? () => controller.switchBranch(message, -1) : null,
          ),
          Text(
            '${index + 1}/${siblings.length}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          action(
            Icons.chevron_right,
            'Next version',
            index < siblings.length - 1
                ? () => controller.switchBranch(message, 1)
                : null,
          ),
        ],
        if (message.content.isNotEmpty)
          action(Icons.copy_outlined, 'Copy', () {
            Clipboard.setData(ClipboardData(text: message.content));
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Copied')));
          }),
        if (isUser)
          action(Icons.edit_outlined, 'Edit', () => _edit(context, ref))
        else
          action(
            Icons.refresh,
            'Regenerate',
            () => controller.regenerate(message),
          ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final text = TextEditingController(text: message.content);
    final edited = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: text,
          autofocus: true,
          minLines: 1,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    text.dispose();
    if (edited != null && edited.trim().isNotEmpty) {
      await ref
          .read(chatControllerProvider.notifier)
          .send(edited, editOf: message);
    }
  }
}

class _Composer extends ConsumerStatefulWidget {
  const _Composer({required this.streaming});
  final bool streaming;

  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final value = _text.text;
    if (value.trim().isEmpty) return;
    _text.clear();
    ref.read(chatControllerProvider.notifier).send(value);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(chatControllerProvider.notifier);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: 'Message',
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            widget.streaming
                ? IconButton.filledTonal(
                    tooltip: 'Stop',
                    icon: const Icon(Icons.stop),
                    onPressed: controller.stop,
                  )
                : IconButton.filled(
                    tooltip: 'Send',
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: _send,
                  ),
          ],
        ),
      ),
    );
  }
}

class _ChatDrawer extends ConsumerWidget {
  const _ChatDrawer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(chatListProvider);
    final session = ref.watch(sessionProvider).value;
    final current = ref.watch(chatControllerProvider).chat?.id;
    return NavigationDrawer(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 16, 8),
          child: Text('Chats', style: Theme.of(context).textTheme.titleMedium),
        ),
        ...chats.when(
          data: (list) => [
            for (final c in list)
              ListTile(
                selected: c.id == current,
                title: Text(
                  c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(context);
                  ref.read(chatControllerProvider.notifier).open(c.id);
                },
              ),
          ],
          loading: () => [
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
          error: (e, _) => [
            ListTile(
              title: const Text('Could not load chats'),
              subtitle: Text('$e'),
              trailing: const Icon(Icons.refresh),
              onTap: () => ref.invalidate(chatListProvider),
            ),
          ],
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.system_update),
          title: const Text('App updates'),
          onTap: () {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const UpdateScreen()),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Sign out'),
          subtitle: Text(session?.serverUrl ?? ''),
          onTap: () => ref.read(sessionProvider.notifier).signOut(),
        ),
      ],
    );
  }
}
