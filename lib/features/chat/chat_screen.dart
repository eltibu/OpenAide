import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../../core/theme.dart';
import '../update/update_screen.dart';
import '../terminal/terminal_screen.dart' show terminalServersProvider;
import 'artifacts_view.dart';
import '../workspace/prompts_api.dart' show Prompt;
import '../workspace/prompts_screen.dart';
import '../voice/call_screen.dart';
import 'attachments.dart';
import 'embeds_view.dart';
import 'chat_controller.dart';
import 'chat_drawer.dart';
import 'request_options.dart';

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
    final title = state.chat?.title;

    return Scaffold(
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            tooltip: 'Chats',
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: Text(
          title == null || title.isEmpty ? '' : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: () =>
                ref.read(chatControllerProvider.notifier).newChat(),
          ),
        ],
      ),
      drawer: const ChatDrawer(),
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

/// The widest a column of chat gets: on a tablet or an unfolded phone the
/// conversation stays a readable column in the middle, as in the Claude app.
const maxReadingWidth = 720.0;

/// The width of that column.
double readingWidth(BuildContext context) =>
    math.min(MediaQuery.sizeOf(context).width, maxReadingWidth);

/// Side padding that keeps content in that column, at least [min].
double readingInset(BuildContext context, double min) => math.max(
  min,
  (MediaQuery.sizeOf(context).width - maxReadingWidth) / 2 + min,
);

/// A new chat: the greeting, centered, as in the Claude app.
class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  static String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 5) return 'Hello, night owl';
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(sessionProvider).value?.userName.split(' ').first;
    final style = Theme.of(context).textTheme.headlineMedium
        ?.copyWith(fontFamily: 'serif', fontWeight: FontWeight.w400);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome, color: NexusColors.accent, size: 36),
            const SizedBox(height: 16),
            Text(
              name == null || name.isEmpty
                  ? _greeting()
                  : '${_greeting()}, $name',
              textAlign: TextAlign.center,
              style: style,
            ),
          ],
        ),
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
    // Pictures in replies load from the server signed in, like the web.
    final images = ImgConfig(
      builder: (url, attributes) =>
          MarkdownImage(url: url, alt: attributes['alt'] ?? ''),
    );
    final mdConfig =
        (dark ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig).copy(
          configs: [images],
        );
    final body = Theme.of(context).textTheme.bodyLarge;
    final artifacts = artifactsOfChat(messages);
    return ListView.builder(
      reverse: true,
      padding: EdgeInsets.symmetric(
        horizontal: readingInset(context, 16),
        vertical: 8,
      ),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final m = messages[messages.length - 1 - i];
        final live = streaming && i == 0;
        if (m.role == 'user') {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (m.attachments.isNotEmpty)
                MessageAttachments(attachments: m.attachments),
              if (m.content.isNotEmpty)
                GestureDetector(
                  onLongPress: streaming
                      ? null
                      : () => _userMessageMenu(context, ref, m),
                  child: Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    constraints: BoxConstraints(
                      maxWidth: readingWidth(context) * 0.82,
                    ),
                    decoration: BoxDecoration(
                      color: context.nexus.userBubble,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(m.content, style: body),
                  ),
                ),
              if (!streaming) _MessageActions(message: m, compact: true),
            ],
          );
        }
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (m.toolCalls.isNotEmpty) _ToolCalls(calls: m.toolCalls),
              if (m.attachments.isNotEmpty)
                MessageAttachments(attachments: m.attachments, alignEnd: false),
              for (final e in m.embeds) EmbedView(key: ValueKey(e), embed: e),
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
              if (live && m.content.isNotEmpty && (status ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    status!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (!live) ArtifactCard(all: artifacts, messageId: m.id),
              if (m.sources.isNotEmpty) _Sources(sources: m.sources),
              if (!live && !streaming) _MessageActions(message: m),
            ],
          ),
        );
      },
    );
  }
}

/// The tools a reply used, folded away like the web UI's tool blocks.
class _ToolCalls extends StatelessWidget {
  const _ToolCalls({required this.calls});
  final List<ToolCall> calls;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        dense: true,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        leading: const Icon(Icons.build_outlined, size: 18),
        title: Text(
          calls.length == 1
              ? 'Used ${calls.first.name}'
              : 'Used ${calls.length} tools',
          style: small,
        ),
        children: [
          for (final c in calls)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: SelectableText(
                  [
                    '${c.name}(${c.arguments})',
                    if (c.result != null)
                      c.result!.length > 600
                          ? '${c.result!.substring(0, 600)}…'
                          : c.result!,
                  ].join('\n'),
                  style: small?.copyWith(fontFamily: 'monospace'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Where a reply's information came from; web links open in the browser.
class _Sources extends StatelessWidget {
  const _Sources({required this.sources});
  final List<Source> sources;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final s in sources)
          ActionChip(
            visualDensity: VisualDensity.compact,
            avatar: Icon(
              s.url != null ? Icons.link : Icons.description_outlined,
              size: 16,
            ),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(s.name, overflow: TextOverflow.ellipsis),
            ),
            onPressed: s.url == null
                ? null
                : () => launchUrl(
                    Uri.parse(s.url!),
                    mode: LaunchMode.externalApplication,
                  ),
          ),
      ],
    ),
  );
}

/// Copy, edit or regenerate, and switching between versions of a message.
class _MessageActions extends ConsumerWidget {
  const _MessageActions({required this.message, this.compact = false});
  final ChatMessage message;

  /// Only the version arrows (user messages: copy and edit are on
  /// long-press, as in the Claude app).
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(chatControllerProvider.notifier);
    final chat = ref.watch(chatControllerProvider).chat;
    final siblings = chat?.siblingsOf(message) ?? const <String>[];
    final index = siblings.indexOf(message.id);
    final isUser = message.role == 'user';
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (compact && siblings.length < 2) return const SizedBox.shrink();

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
        if (!compact && message.content.isNotEmpty)
          action(Icons.copy_outlined, 'Copy', () {
            Clipboard.setData(ClipboardData(text: message.content));
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Copied')));
          }),
        if (isUser || compact)
          const SizedBox.shrink()
        else
          action(
            Icons.refresh,
            'Regenerate',
            () => controller.regenerate(message),
          ),
      ],
    );
  }

  static Future<void> edit(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
  ) async {
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
    if (edited != null &&
        (edited.trim().isNotEmpty || message.attachments.isNotEmpty)) {
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
    final controller = ref.read(chatControllerProvider.notifier);
    final files = ref
        .read(chatControllerProvider)
        .attachments
        .any((a) => a.uploaded != null);
    // Keep the draft when it can't go anywhere yet, rather than losing it.
    if ((value.trim().isEmpty && !files) || !controller.canSend) return;
    _text.clear();
    controller.send(value);
  }

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      final has = _text.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
      // "/" at the start offers the person's saved prompts, as on the web.
      final slash = RegExp(r'^/(\S*)$').firstMatch(_text.text)?.group(1);
      if (slash != _slash) setState(() => _slash = slash);
    });
  }

  bool _hasText = false;
  String? _slash;

  Future<void> _usePrompt(Prompt p) async {
    setState(() => _slash = null);
    final text = await resolvePrompt(context, ref, p);
    if (text == null) return;
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(chatControllerProvider.notifier);
    final ready = ref.watch(
      chatControllerProvider.select(
        (s) =>
            s.modelId != null &&
            !s.loading &&
            !s.attachments.any((a) => a.uploading),
      ),
    );
    final hasFiles = ref.watch(
      chatControllerProvider.select(
        (s) => s.attachments.any((a) => a.uploaded != null),
      ),
    );
    final empty = ref.watch(
      chatControllerProvider.select((s) => s.messages.isEmpty),
    );
    final colors = context.nexus;
    final Widget action;
    if (widget.streaming) {
      action = IconButton.filled(
        tooltip: 'Stop',
        icon: const Icon(Icons.stop_rounded),
        onPressed: controller.stop,
      );
    } else if (_hasText || hasFiles) {
      action = IconButton.filled(
        tooltip: 'Send',
        icon: const Icon(Icons.arrow_upward),
        onPressed: ready ? _send : null,
      );
    } else {
      action = IconButton.filled(
        tooltip: 'Voice call',
        icon: const Icon(Icons.graphic_eq),
        onPressed: ready
            ? () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const CallScreen()),
              )
            : null,
      );
    }
    return SafeArea(
      top: false,
      child: Container(
        margin: EdgeInsets.fromLTRB(
          readingInset(context, 10),
          4,
          readingInset(context, 10),
          10,
        ),
        decoration: BoxDecoration(
          color: colors.composer,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: colors.composerBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PendingAttachments(),
            if (_slash != null)
              PromptSuggestions(query: _slash!, onPick: _usePrompt),
            TextField(
              controller: _text,
              minLines: 1,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: empty ? 'Chat with Nexus' : 'Reply to Nexus',
                border: InputBorder.none,
                contentPadding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  const AttachButton(),
                  const _FeaturesButton(),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _ModelChip(),
                    ),
                  ),
                  action,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The model in use, as a chip in the text box; tap to switch.
class _ModelChip extends ConsumerWidget {
  const _ModelChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(modelsProvider);
    final selected = ref.watch(chatControllerProvider.select((s) => s.modelId));
    final list = models.value ?? const [];
    final name = models.isLoading
        ? 'Loading…'
        : list.where((m) => m.id == selected).firstOrNull?.name ??
              (models.hasError ? 'Models unavailable' : 'Choose a model');
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: context.nexus.muted,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      ),
      onPressed: models.hasError
          ? () => ref.invalidate(modelsProvider)
          : list.isEmpty
          ? null
          : () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              isScrollControlled: true,
              builder: (context) => SafeArea(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.7,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final m in list)
                        ListTile(
                          title: Text(m.name),
                          subtitle: m.description == null
                              ? null
                              : Text(
                                  m.description!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: m.id == selected
                              ? const Icon(
                                  Icons.check,
                                  color: NexusColors.accent,
                                )
                              : null,
                          onTap: () {
                            ref
                                .read(chatControllerProvider.notifier)
                                .selectModel(m.id);
                            Navigator.pop(context);
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
          const Icon(Icons.expand_more, size: 18),
        ],
      ),
    );
  }
}

/// Long-press on your own message: copy or edit it.
Future<void> _userMessageMenu(
  BuildContext context,
  WidgetRef ref,
  ChatMessage m,
) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text('Copy'),
            onTap: () => Navigator.pop(context, 'copy'),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit'),
            onTap: () => Navigator.pop(context, 'edit'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (choice == 'copy') {
    await Clipboard.setData(ClipboardData(text: m.content));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Copied')));
    }
  } else if (choice == 'edit') {
    await _MessageActions.edit(context, ref, m);
  }
}

/// The web UI's "+" menu: web search, image generation, code interpreter,
/// shown only when the server and the chosen model allow them.
class _FeaturesButton extends ConsumerWidget {
  const _FeaturesButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatControllerProvider);
    final model = ref
        .watch(modelsProvider)
        .value
        ?.where((m) => m.id == state.modelId)
        .firstOrNull;
    final config = ref.watch(serverConfigProvider).value;
    final features = availableFeatures(model, config);
    final tools = ref.watch(toolsProvider).value ?? const [];
    final skills = ref.watch(skillsProvider).value ?? const [];
    final terminals = ref.watch(terminalServersProvider).value ?? const [];
    if (features.isEmpty &&
        tools.isEmpty &&
        skills.isEmpty &&
        terminals.isEmpty) {
      return const SizedBox.shrink();
    }
    bool on(String id) =>
        state.features[id] ?? model?.defaultFeatureIds.contains(id) ?? false;
    final activeTools = state.toolIds ?? model?.toolIds.toSet() ?? const {};
    final terminalId = state.terminalId ?? model?.terminalId ?? '';
    final terminal = terminals.where((t) => t.id == terminalId).firstOrNull;
    final count = activeTools.length + (state.skillIds?.length ?? 0);
    final accent = NexusColors.accent;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Tools',
          visualDensity: VisualDensity.compact,
          color: context.nexus.muted,
          icon: Badge(
            isLabelVisible: count > 0,
            backgroundColor: accent,
            label: Text('$count'),
            child: const Icon(Icons.tune),
          ),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            isScrollControlled: true,
            builder: (context) => const _ToolsSheet(),
          ),
        ),
        // What's switched on, at a glance, as in the web UI's text box.
        if (on('web_search')) Icon(Icons.language, size: 20, color: accent),
        if (on('image_generation'))
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(Icons.image_outlined, size: 20, color: accent),
          ),
        if (on('code_interpreter'))
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(Icons.code, size: 20, color: accent),
          ),
        if (terminal != null)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Tooltip(
              message: terminal.name,
              child: Icon(Icons.terminal, size: 20, color: accent),
            ),
          ),
      ],
    );
  }
}

/// The web UI's tools menu: features, tools, skills and the terminal.
class _ToolsSheet extends ConsumerWidget {
  const _ToolsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatControllerProvider);
    final chat = ref.read(chatControllerProvider.notifier);
    final model = ref
        .watch(modelsProvider)
        .value
        ?.where((m) => m.id == state.modelId)
        .firstOrNull;
    final config = ref.watch(serverConfigProvider).value;
    final features = availableFeatures(model, config);
    final tools = ref.watch(toolsProvider).value ?? const [];
    final skills = ref.watch(skillsProvider).value ?? const [];
    final terminals = ref.watch(terminalServersProvider).value ?? const [];
    final activeTools = state.toolIds ?? model?.toolIds.toSet() ?? const {};
    final terminalId = state.terminalId ?? model?.terminalId ?? '';
    final heading = Theme.of(context).textTheme.labelLarge
        ?.copyWith(color: context.nexus.muted);
    Widget title(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(text, style: heading),
    );
    String? describe(Pickable p) =>
        (p.description ?? '').isEmpty ? null : p.description;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            if (features.isNotEmpty) ...[
              title('Features'),
              for (final id in features)
                SwitchListTile(
                  secondary: Icon(switch (id) {
                    'web_search' => Icons.language,
                    'image_generation' => Icons.image_outlined,
                    _ => Icons.code,
                  }),
                  title: Text(featureLabels[id] ?? id),
                  value:
                      state.features[id] ??
                      model?.defaultFeatureIds.contains(id) ??
                      false,
                  onChanged: (v) => chat.setFeature(id, v),
                ),
            ],
            if (terminals.isNotEmpty) ...[
              title('Terminal'),
              RadioGroup<String>(
                groupValue: terminalId,
                onChanged: (v) => chat.setTerminal(v ?? ''),
                child: Column(
                  children: [
                    const RadioListTile<String>(
                      value: '',
                      title: Text('No terminal'),
                    ),
                    for (final t in terminals)
                      RadioListTile<String>(
                        value: t.id,
                        title: Text(t.name),
                        secondary: const Icon(Icons.terminal),
                      ),
                  ],
                ),
              ),
            ],
            if (tools.isNotEmpty) ...[
              title('Tools'),
              for (final t in tools)
                SwitchListTile(
                  title: Text(t.name),
                  subtitle: describe(t) == null ? null : Text(describe(t)!),
                  value: activeTools.contains(t.id),
                  onChanged: (v) => chat.setTool(t.id, v),
                ),
            ],
            if (skills.isNotEmpty) ...[
              title('Skills'),
              for (final t in skills)
                SwitchListTile(
                  title: Text(t.name),
                  subtitle: describe(t) == null ? null : Text(describe(t)!),
                  value: state.skillIds?.contains(t.id) ?? false,
                  onChanged: (v) => chat.setSkill(t.id, v),
                ),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
