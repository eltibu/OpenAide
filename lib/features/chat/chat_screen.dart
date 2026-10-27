import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../../core/theme.dart';
import '../../core/widgets/nexus_logo.dart';
import '../update/update_screen.dart';
import '../terminal/file_links.dart' show FileRef;
import '../terminal/file_open.dart';
import '../terminal/terminal_screen.dart' show terminalServersProvider;
import 'artifacts_view.dart';
import '../workspace/prompts_api.dart' show Prompt;
import '../workspace/prompts_screen.dart';
import '../voice/call_screen.dart';
import 'attachments.dart';
import 'attach_more.dart';
import 'chat_controls.dart';
import 'chat_panel.dart';
import 'emoji.dart';
import 'embeds_view.dart';
import 'markdown_extras.dart';
import 'read_aloud.dart';
import 'reply_actions.dart';
import 'reply_parts.dart';
import 'reply_steps.dart';
import 'side_panel.dart';
import 'chat_controller.dart';
import 'composer_draft.dart';
import 'reply_notify.dart';
import 'chat_drawer.dart';
import 'request_options.dart';
import 'tool_approval.dart';
import 'voice_note.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  /// Wide screens: the chat list docked on the left (the menu button hides
  /// and shows it), and what is open in the right panel.
  bool _nav = true;
  SidePanelContent? _panel;

  /// Keeps the conversation (and where it is scrolled to) when the panels
  /// around it change or the phone folds.
  final _chatKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // A tapped reply notification opens its chat.
    listenForReplyTaps((id) {
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      ref.read(chatControllerProvider.notifier).open(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= wideLayout;
    final chat = KeyedSubtree(key: _chatKey, child: _chat(context, wide));
    if (!wide) return chat;
    final panelWidth = (size.width * 0.5).clamp(340.0, 720.0);
    // The chat lays itself out for the room it has, not the whole screen.
    Widget fit(Widget child) => LayoutBuilder(
      builder: (context, c) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(size: Size(c.maxWidth, size.height)),
        child: child,
      ),
    );
    final showNav = _nav && _panel == null;
    return SidePanelHost(
      current: _panel,
      open: (content) => setState(() => _panel = content),
      close: () => setState(() => _panel = null),
      child: Row(
        children: [
          if (showNav) ...[
            const SizedBox(
              key: ValueKey('nav'),
              width: 300,
              child: ChatDrawer(docked: true),
            ),
            const VerticalDivider(key: ValueKey('navLine'), width: 1),
          ],
          Expanded(key: const ValueKey('chat'), child: fit(chat)),
          if (_panel != null) ...[
            const VerticalDivider(key: ValueKey('panelLine'), width: 1),
            SizedBox(
              key: const ValueKey('panel'),
              width: panelWidth,
              child: fit(
                SidePanelView(
                  content: _panel!,
                  close: () => setState(() => _panel = null),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chat(BuildContext context, bool wide) {
    final state = ref.watch(chatControllerProvider);

    // Start with your default model once it is known.
    final preferred = ref.watch(defaultModelProvider).value;
    if (state.modelId == null && preferred != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ref.read(chatControllerProvider).modelId == null) {
          ref.read(chatControllerProvider.notifier).selectModel(preferred);
        }
      });
    }
    final title = state.chat?.title;

    return Scaffold(
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            tooltip: 'Chats',
            icon: const Icon(Icons.menu),
            onPressed: () => wide
                // Docked: hide or show it; with a panel open, the panel
                // closes and the list comes back.
                ? setState(() {
                    if (_panel != null) {
                      _panel = null;
                      _nav = true;
                    } else {
                      _nav = !_nav;
                    }
                  })
                : Scaffold.of(context).openDrawer(),
          ),
        ),
        title: Text(
          title == null || title.isEmpty ? '' : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // As on the web: switch a new chat to temporary before it starts.
          if (state.messages.isEmpty || state.temporary)
            IconButton(
              tooltip: state.temporary
                  ? 'Temporary chat: not saved'
                  : 'Temporary chat',
              isSelected: state.temporary,
              icon: const Icon(Icons.history_toggle_off),
              selectedIcon: const Icon(
                Icons.visibility_off_outlined,
                color: NexusColors.accent,
              ),
              onPressed: () => ref
                  .read(chatControllerProvider.notifier)
                  .newChat(temporary: !state.temporary),
            ),
          // The web's chat panel: Controls, Files and Overview.
          IconButton(
            tooltip: 'Controls, files and overview',
            isSelected: state.params.isNotEmpty,
            icon: const Icon(Icons.tune),
            selectedIcon: const Icon(Icons.tune, color: NexusColors.accent),
            onPressed: () => showChatPanel(context),
          ),
          const ReadAloudButton(),
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: () =>
                ref.read(chatControllerProvider.notifier).newChat(),
          ),
        ],
      ),
      drawer: wide ? null : const ChatDrawer(),
      body: Column(
        children: [
          const UpdateBanner(),
          if (state.temporary) const _TemporaryBar(),
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

/// Says the chat isn't being saved, with a way to keep it.
class _TemporaryBar extends ConsumerWidget {
  const _TemporaryBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(chatControllerProvider.notifier);
    final canSave = ref.watch(
      chatControllerProvider.select(
        (s) => s.messages.isNotEmpty && !s.streaming,
      ),
    );
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(
              Icons.visibility_off_outlined,
              size: 18,
              color: context.nexus.muted,
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text("Temporary chat. It won't be saved or kept."),
            ),
            if (canSave)
              TextButton(
                onPressed: controller.saveTemporary,
                child: const Text('Save it'),
              )
            else
              TextButton(
                onPressed: () => controller.newChat(),
                child: const Text('Turn off'),
              ),
          ],
        ),
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
    final style = Theme.of(context).textTheme.headlineSmall
        ?.copyWith(fontFamily: 'serif', fontWeight: FontWeight.w400);
    // Scrolls when the keyboard leaves too little room.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const NexusLogo(size: 56),
            const SizedBox(height: 12),
            Text(
              name == null || name.isEmpty
                  ? _greeting()
                  : '${_greeting()}, $name',
              textAlign: TextAlign.center,
              style: style,
            ),
            const _Suggestions(),
          ],
        ),
      ),
    );
  }
}

bool insertSuggestion(WidgetRef ref) =>
    (ref.read(userSettingsProvider).value?['ui']
        as Map?)?['insertSuggestionPrompt'] ==
    true;

/// Starter prompts under the greeting, as the web UI shows them.
class _Suggestions extends ConsumerWidget {
  const _Suggestions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modelId = ref.watch(chatControllerProvider.select((s) => s.modelId));
    final models = ref.watch(modelsProvider).value ?? const [];
    final config = ref.watch(serverConfigProvider).value;
    final list = promptSuggestions(
      models.where((m) => m.id == modelId).firstOrNull?.meta,
      config,
    ).take(4).toList();
    if (list.isEmpty) return const SizedBox.shrink();
    final muted = context.nexus.muted;
    final text = Theme.of(context).textTheme;
    // Small rows under a "Suggested" label, as the web shows them, instead
    // of full cards that crowd a phone screen.
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome_outlined, size: 14, color: muted),
                  const SizedBox(width: 6),
                  Text(
                    'Suggested',
                    style: text.labelMedium?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            for (final p in list)
              InkWell(
                borderRadius: BorderRadius.circular(10),
                // Settings > Interface can put it in the box to edit first.
                onTap: () => insertSuggestion(ref)
                    ? ref.read(composerDraftProvider.notifier).put(p.content)
                    : ref.read(chatControllerProvider.notifier).send(p.content),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (p.subtitle.isNotEmpty)
                        Text(
                          p.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(color: muted),
                        ),
                    ],
                  ),
                ),
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
    // Settings > Chats choices for how messages show.
    final ui =
        (ref.watch(userSettingsProvider).value?['ui'] as Map?) ?? const {};
    final userMarkdown = ui['renderMarkdownInUserMessages'] != false;
    final keepFollowUps = ui['keepFollowUpPrompts'] == true;
    // Pictures in replies load from the server signed in, like the web.
    final images = ImgConfig(
      builder: (url, attributes) =>
          MarkdownImage(url: url, alt: attributes['alt'] ?? ''),
    );
    // A file a reply names opens in Files, on the chat's terminal.
    void openFile(FileRef file) {
      final chat = ref.read(chatControllerProvider);
      final model = ref
          .read(modelsProvider)
          .value
          ?.where((m) => m.id == chat.modelId)
          .firstOrNull;
      openFileRef(
        context,
        ref,
        file,
        terminalId: chat.terminalId ?? model?.terminalId,
      );
    }

    final mdConfig = withFileLinks(
      withReplyCode(
        (dark ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig).copy(
          configs: [images],
        ),
        dark,
        collapse: ui['collapseCodeBlocks'] == true,
      ),
      openFile,
    );
    final generator = withFileTaps(replyMarkdownGenerator(), openFile);
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
                    child: userMarkdown
                        ? MarkdownBlock(
                            data: m.content,
                            config: mdConfig.copy(
                              configs: [PConfig(textStyle: body!)],
                            ),
                            generator: generator,
                          )
                        : Text(m.content, style: body),
                  ),
                ),
              if (!streaming) _MessageActions(message: m, compact: true),
            ],
          );
        }
        final groups = groupParts(replyParts(m, live: live));
        final waiting = live ? null : pendingCall(m);
        final firstText = groups.indexWhere((g) => g is TextPart);
        final working =
            live &&
            groups.any((g) => g is List<StepPart> && g.any((s) => !s.done));
        final embeds = [
          for (final e in m.embeds) EmbedView(key: ValueKey(e), embed: e),
        ];
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ModelAnswers(reply: m, isLast: i == 0),
              if (m.attachments.isNotEmpty)
                MessageAttachments(attachments: m.attachments, alignEnd: false),
              for (var g = 0; g < groups.length; g++) ...[
                if (g == firstText) ...embeds,
                switch (groups[g]) {
                  final TextPart t => MarkdownBlock(
                    data: t.text,
                    config: mdConfig,
                    generator: generator,
                  ),
                  final steps => ReplySteps(
                    steps: steps as List<StepPart>,
                    live: live,
                    open: ui['expandDetails'] == true,
                  ),
                },
              ],
              if (firstText < 0) ...embeds,
              if (firstText < 0 && live && !working)
                Row(
                  children: [
                    const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    if (groups.isEmpty && (status ?? '').isNotEmpty) ...[
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
              else if (firstText < 0 && !live && waiting == null)
                Text(
                  m.error ?? 'No reply. Tap Retry above to ask again.',
                  style: TextStyle(color: scheme.error),
                ),
              if (!live) ArtifactCard(all: artifacts, messageId: m.id),
              if (m.sources.isNotEmpty) _Sources(sources: m.sources),
              if (waiting != null && !streaming)
                PendingCallCard(reply: m, call: waiting),
              if (!live && !streaming && waiting == null)
                _MessageActions(message: m, isLast: i == 0),
              if ((i == 0 || keepFollowUps) && !live && !streaming)
                FollowUps(reply: m),
            ],
          ),
        );
      },
    );
  }
}

/// When several models answered the same message: the merged answer, if
/// made, and a tab per model to switch between their replies, as the web's
/// side-by-side answers do on a phone.
class _ModelAnswers extends ConsumerWidget {
  const _ModelAnswers({required this.reply, required this.isLast});
  final ChatMessage reply;
  final bool isLast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatControllerProvider);
    final controller = ref.read(chatControllerProvider.notifier);
    final user = state.chat?.messages[reply.parentId];
    if (user == null || user.role != 'user') return const SizedBox.shrink();
    final answers = controller.answersTo(user);
    if (answers.length < 2) return const SizedBox.shrink();
    final names = {
      for (final m in ref.watch(modelsProvider).value ?? const []) m.id: m.name,
    };
    final merged = [
      for (final a in answers)
        if (a.extra['merged'] is Map) a.extra['merged'] as Map,
    ].firstOrNull;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if ('${merged?['content'] ?? ''}'.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.merge, size: 18, color: theme.hintColor),
                    const SizedBox(width: 6),
                    Text('Merged answer', style: theme.textTheme.labelLarge),
                  ],
                ),
                const SizedBox(height: 4),
                MarkdownBlock(data: '${merged!['content']}', selectable: true),
              ],
            ),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final a in answers)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(names[a.model] ?? a.model ?? 'Model'),
                    selected: a.id == reply.id,
                    onSelected: (_) => controller.showAnswer(a),
                  ),
                ),
              if (isLast && !state.streaming)
                TextButton.icon(
                  icon: const Icon(Icons.merge, size: 18),
                  label: Text(merged == null ? 'Merge' : 'Merge again'),
                  onPressed: () => controller.merge(reply),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
      ],
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
            onPressed: s.passages.isNotEmpty
                ? () => showSource(context, s)
                : s.url == null
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
  const _MessageActions({
    required this.message,
    this.compact = false,
    this.isLast = false,
  });
  final ChatMessage message;

  /// The newest reply in the chat (it can be continued).
  final bool isLast;

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
    final rating = ratingOf(message);
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

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
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
          if (!isUser && !compact) ...[
            if (message.content.isNotEmpty)
              SpeakButton(reply: message, color: muted),
            action(
              rating == 1 ? Icons.thumb_up : Icons.thumb_up_outlined,
              'Good reply',
              () => rateReply(context, ref, message, 1),
            ),
            action(
              rating == -1 ? Icons.thumb_down : Icons.thumb_down_outlined,
              'Bad reply',
              () => rateReply(context, ref, message, -1),
            ),
            RegenerateButton(reply: message, color: muted),
            action(
              Icons.call_split,
              'Fork from here',
              () => controller.fork(message),
            ),
            ReplyMoreButton(reply: message, color: muted, isLast: isLast),
          ],
        ],
      ),
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

  void _queue() {
    final value = _text.text;
    if (value.trim().isEmpty) return;
    _text.clear();
    ref.read(chatControllerProvider.notifier).queue(value);
  }

  void _steer() {
    final value = _text.text;
    if (value.trim().isEmpty) return;
    _text.clear();
    ref.read(chatControllerProvider.notifier).steer(value);
  }

  void _fill(String text) => _text.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );

  @override
  void initState() {
    super.initState();
    ref.listenManual(composerDraftProvider, (_, text) {
      if (text == null) return;
      _fill(text);
      ref.read(composerDraftProvider.notifier).clear();
    });
    _text.addListener(() {
      final has = _text.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
      // "/" at the start offers the person's saved prompts, as on the web.
      final slash = RegExp(r'^/(\S*)$').firstMatch(_text.text)?.group(1);
      if (slash != _slash) setState(() => _slash = slash);
      // "@" picks the model for this chat, as on the web.
      final at = RegExp(r'(?:^|\s)@(\S*)$').firstMatch(_text.text)?.group(1);
      if (at != _at) setState(() => _at = at);
      // "#" attaches knowledge, a note or a web page, as on the web.
      final hash = RegExp(r'(?:^|\s)#(\S*)$').firstMatch(_text.text)?.group(1);
      if (hash != _hash) setState(() => _hash = hash);
      // ":" and two letters suggests emoji, as on the web.
      final colon = RegExp(r'(?:^|\s):([a-z0-9_+\-]{2,})$')
          .firstMatch(_text.text)
          ?.group(1);
      if (colon != _colon) setState(() => _colon = colon);
    });
  }

  bool _hasText = false;
  bool _recording = false;
  String? _slash;
  String? _at;
  String? _hash;
  String? _colon;

  void _pickEmoji(String emoji) {
    final text = _text.text.replaceFirst(RegExp(r':[a-z0-9_+\-]*$'), emoji);
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _dropHash() {
    final text = _text.text.replaceFirst(RegExp(r'#\S*$'), '');
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// The app's own "/" commands, listed above your saved prompts.
  List<SlashCommand> _commands() {
    final controller = ref.read(chatControllerProvider.notifier);
    final state = ref.read(chatControllerProvider);
    final readAloud = ref.read(readAloudOnProvider);
    final lastReply = state.messages.lastWhere(
      (m) => m.role == 'assistant',
      orElse: () => ChatMessage(id: '', role: '', content: ''),
    );
    void run(VoidCallback action) {
      _text.clear();
      action();
    }

    final model = ref
        .read(modelsProvider)
        .value
        ?.where((m) => m.id == state.modelId)
        .firstOrNull;
    final features = availableFeatures(
      model,
      ref.read(serverConfigProvider).value,
    );
    bool featureOn(String id) =>
        state.features[id] ?? model?.defaultFeatureIds.contains(id) ?? false;

    return [
      if (state.streaming)
        SlashCommand('stop', 'Stop the reply', Icons.stop_rounded, () {
          run(controller.stop);
        }),
      if (lastReply.id.isNotEmpty && !state.streaming)
        SlashCommand(
          'fork',
          'Fork: a new chat with this conversation so far',
          Icons.call_split,
          () => run(() => controller.fork(lastReply)),
        ),
      SlashCommand(
        'read',
        readAloud
            ? 'Read aloud is on: turn it off'
            : 'Read aloud: Nexus speaks every reply',
        readAloud ? Icons.volume_off_outlined : Icons.volume_up_outlined,
        () => run(() => ref.read(readAloudOnProvider.notifier).set(!readAloud)),
      ),
      if (lastReply.id.isNotEmpty && !state.streaming)
        SlashCommand(
          'retry',
          'Ask again for the last reply',
          Icons.refresh,
          () => run(() => controller.regenerate(lastReply)),
        ),
      if (lastReply.content.isNotEmpty)
        SlashCommand('copy', 'Copy the last reply', Icons.copy_outlined, () {
          run(() {
            Clipboard.setData(ClipboardData(text: lastReply.content));
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Copied')));
          });
        }),
      SlashCommand(
        'model',
        'Switch the model for this chat',
        Icons.swap_horiz,
        () {
          _text.value = const TextEditingValue(
            text: '@',
            selection: TextSelection.collapsed(offset: 1),
          );
        },
      ),
      // The text box's switches and + menu, without leaving the keyboard.
      for (final id in features)
        SlashCommand(
          switch (id) {
            'web_search' => 'search',
            'image_generation' => 'image',
            _ => 'code',
          },
          '${featureOn(id) ? 'Turn off' : 'Turn on'} ${switch (id) {
            'web_search' => 'web search',
            'image_generation' => 'image generation',
            _ => 'the code interpreter',
          }} for this chat',
          _featureIcon(id),
          () => run(() => controller.setFeature(id, !featureOn(id))),
        ),
      SlashCommand(
        'knowledge',
        'Attach knowledge or a note (or type #)',
        Icons.library_books_outlined,
        () {
          _text.value = const TextEditingValue(
            text: '#',
            selection: TextSelection.collapsed(offset: 1),
          );
        },
      ),
      SlashCommand(
        'controls',
        "This chat's system prompt and model settings",
        Icons.settings_suggest_outlined,
        () => run(() => showChatControls(context)),
      ),
      SlashCommand('web', 'Attach a web page', Icons.language, () {
        run(() => attachWebpage(context, ref));
      }),
      SlashCommand(
        'note',
        'Attach one of your notes',
        Icons.sticky_note_2_outlined,
        () {
          run(() => attachFromServer(context, ref, 'note'));
        },
      ),
      SlashCommand('chat', 'Attach a past chat', Icons.forum_outlined, () {
        run(() => attachFromServer(context, ref, 'chat'));
      }),
      if (state.temporary && state.messages.isNotEmpty && !state.streaming)
        SlashCommand(
          'save',
          'Save this temporary chat',
          Icons.save_outlined,
          () => run(controller.saveTemporary),
        )
      else if (state.messages.isEmpty)
        SlashCommand(
          'temporary',
          state.temporary
              ? 'Temporary chat is on: turn it off'
              : "Temporary chat: one that isn't saved",
          Icons.visibility_off_outlined,
          () => run(() => controller.newChat(temporary: !state.temporary)),
        ),
      SlashCommand('new', 'Start a new chat', Icons.add_comment_outlined, () {
        run(controller.newChat);
      }),
      if (!state.streaming)
        SlashCommand('call', 'Start a voice call', Icons.graphic_eq, () {
          run(
            () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const CallScreen()),
            ),
          );
        }),
    ];
  }

  void _pickModel(String id) {
    ref.read(chatControllerProvider.notifier).selectModel(id);
    final text = _text.text.replaceFirst(RegExp(r'@\S*$'), '');
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

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
    if (widget.streaming && _hasText) {
      // Steer: stop the reply where it is and send this instead.
      action = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Stop',
            icon: const Icon(Icons.stop_rounded),
            onPressed: controller.stop,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Steer: stop the reply and send this now',
            icon: const Icon(Icons.turn_right),
            onPressed: _steer,
          ),
          IconButton.filled(
            visualDensity: VisualDensity.compact,
            tooltip: 'Queue: send this when the reply is done',
            icon: const Icon(Icons.arrow_upward),
            onPressed: _queue,
          ),
        ],
      );
    } else if (widget.streaming) {
      action = IconButton.filled(
        visualDensity: VisualDensity.compact,
        tooltip: 'Stop',
        icon: const Icon(Icons.stop_rounded),
        onPressed: controller.stop,
      );
    } else if (_hasText || hasFiles) {
      action = IconButton.filled(
        visualDensity: VisualDensity.compact,
        tooltip: 'Send',
        icon: const Icon(Icons.arrow_upward),
        onPressed: ready ? _send : null,
      );
    } else {
      action = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Record a voice note',
            icon: const Icon(Icons.mic_none),
            onPressed: ready ? () => setState(() => _recording = true) : null,
          ),
          IconButton.filled(
            visualDensity: VisualDensity.compact,
            tooltip: 'Voice call',
            icon: const Icon(Icons.graphic_eq),
            onPressed: ready
                ? () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (_) => const CallScreen()),
                  )
                : null,
          ),
        ],
      );
    }
    return SafeArea(
      top: false,
      child: Container(
        margin: EdgeInsets.fromLTRB(
          readingInset(context, 8),
          2,
          readingInset(context, 8),
          8,
        ),
        decoration: BoxDecoration(
          color: colors.composer,
          borderRadius: BorderRadius.circular(22),
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
            _QueuedMessages(onEdit: _fill),
            if (_recording)
              VoiceNoteBar(
                onDone: () => setState(() => _recording = false),
                onWords: (words) {
                  final before = _text.text.trimRight();
                  final text = before.isEmpty ? words : '$before $words';
                  _text.value = TextEditingValue(
                    text: text,
                    selection: TextSelection.collapsed(offset: text.length),
                  );
                },
              )
            else ...[
              if (_at != null) _ModelMentions(query: _at!, onPick: _pickModel),
              if (_colon != null)
                EmojiSuggestions(query: _colon!, onPick: _pickEmoji),
              if (_hash != null) HashMentions(query: _hash!, onDone: _dropHash),
              if (_slash != null)
                PromptSuggestions(
                  query: _slash!,
                  onPick: _usePrompt,
                  commands: _commands(),
                ),
              TextField(
                controller: _text,
                minLines: 1,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: empty ? 'Chat with Nexus' : 'Reply to Nexus',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                ),
              ),
              // One slim row of small buttons under the text, as on the web.
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
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
          ],
        ),
      ),
    );
  }
}

/// Messages waiting for the running reply to finish.
class _QueuedMessages extends ConsumerWidget {
  const _QueuedMessages({required this.onEdit});
  final ValueChanged<String> onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queued = ref.watch(chatControllerProvider.select((s) => s.queued));
    if (queued.isEmpty) return const SizedBox.shrink();
    final controller = ref.read(chatControllerProvider.notifier);
    final muted = context.nexus.muted;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.schedule, size: 16, color: muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  queued.length == 1
                      ? 'Queued: sends when the reply is done'
                      : '${queued.length} queued: sent together when the '
                            'reply is done',
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: muted),
                ),
              ),
              TextButton(
                onPressed: controller.sendQueued,
                child: const Text('Send now'),
              ),
            ],
          ),
          for (final (i, text) in queued.indexed)
            Row(
              children: [
                const SizedBox(width: 22),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Edit',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () => onEdit(controller.unqueue(i)),
                ),
                IconButton(
                  tooltip: 'Remove',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => controller.unqueue(i),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Models matching what follows "@", to switch to.
class _ModelMentions extends ConsumerWidget {
  const _ModelMentions({required this.query, required this.onPick});
  final String query;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = query.toLowerCase();
    final selected = ref.watch(chatControllerProvider.select((s) => s.modelId));
    final models = [
      for (final m in ref.watch(modelsProvider).value ?? const [])
        if (m.name.toLowerCase().contains(q) || m.id.toLowerCase().contains(q))
          m,
    ];
    if (models.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(top: 6),
        children: [
          for (final m in models)
            ListTile(
              dense: true,
              leading: const Icon(Icons.smart_toy_outlined),
              title: Text(m.name),
              subtitle: m.description == null
                  ? null
                  : Text(
                      m.description!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: m.id == selected
                  ? const Icon(Icons.check, color: NexusColors.accent)
                  : null,
              onTap: () => onPick(m.id),
            ),
        ],
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
    final compare = ref.watch(
      chatControllerProvider.select((s) => s.compareIds),
    );
    final list = models.value ?? const [];
    final name = models.isLoading
        ? 'Loading…'
        : (list.where((m) => m.id == selected).firstOrNull?.name ??
                  (models.hasError ? 'Models unavailable' : 'Choose a model')) +
              (compare.isEmpty ? '' : ' +${compare.length}');
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
                  child: Consumer(
                    builder: (context, ref, _) {
                      final state = ref.watch(chatControllerProvider);
                      final selected = state.modelId;
                      final compare = state.compareIds;
                      final chat = ref.read(chatControllerProvider.notifier);
                      return ListView(
                        shrinkWrap: true,
                        children: [
                          const Padding(
                            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Text(
                              'Tap a model to use it. Tap + to have it answer '
                              'too, so you can compare.',
                            ),
                          ),
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
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (m.id == selected)
                                    const Icon(
                                      Icons.check,
                                      color: NexusColors.accent,
                                    )
                                  else
                                    IconButton(
                                      tooltip: compare.contains(m.id)
                                          ? 'Stop comparing'
                                          : 'Compare: have it answer too',
                                      icon: Icon(
                                        compare.contains(m.id)
                                            ? Icons.remove_circle
                                            : Icons.add_circle_outline,
                                        color: compare.contains(m.id)
                                            ? NexusColors.accent
                                            : null,
                                      ),
                                      onPressed: () => chat.setCompare(
                                        compare.contains(m.id)
                                            ? [
                                                for (final c in compare)
                                                  if (c != m.id) c,
                                              ]
                                            : [...compare, m.id],
                                      ),
                                    ),
                                  _DefaultStar(id: m.id),
                                ],
                              ),
                              onTap: () {
                                chat
                                  ..selectModel(m.id)
                                  ..setCompare([
                                    for (final c in compare)
                                      if (c != m.id) c,
                                  ]);
                                Navigator.pop(context);
                              },
                            ),
                        ],
                      );
                    },
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

/// Makes a model the one every new chat starts with; kept in your
/// settings on the server, so the web UI starts with it too.
class _DefaultStar extends ConsumerWidget {
  const _DefaultStar({required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDefault = ref.watch(defaultModelProvider).value == id;
    return IconButton(
      tooltip: isDefault ? 'Your default model' : 'Make this the default',
      onPressed: isDefault
          ? null
          : () async {
              try {
                await ref
                    .read(clientProvider)
                    .send(
                      'POST',
                      '/api/v1/users/user/settings/update',
                      body: {
                        'ui': {
                          'models': [id],
                        },
                      },
                    );
                ref.invalidate(userSettingsProvider);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Couldn\'t set the default: $e')),
                  );
                }
              }
            },
      icon: Icon(
        isDefault ? Icons.star : Icons.star_border,
        color: isDefault ? NexusColors.accent : null,
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
          ListTile(
            leading: const Icon(Icons.call_split),
            title: const Text('Fork from here'),
            subtitle: const Text('A new chat with the conversation so far'),
            onTap: () => Navigator.pop(context, 'fork'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete'),
            subtitle: const Text('This message and the reply to it'),
            onTap: () => Navigator.pop(context, 'delete'),
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
  } else if (choice == 'fork') {
    await ref.read(chatControllerProvider.notifier).fork(m);
  } else if (choice == 'delete') {
    if (await confirm(
      context,
      'Delete this message?',
      'The message and the reply to it are removed from the chat on the '
          'server too.',
    )) {
      await ref.read(chatControllerProvider.notifier).deleteMessage(m);
    }
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

/// The web UI's tools menu: features, tools, skills and the terminal, in
/// groups that fold away, with what's on listed first and a search when
/// the lists are long.
class _ToolsSheet extends ConsumerStatefulWidget {
  const _ToolsSheet();

  @override
  ConsumerState<_ToolsSheet> createState() => _ToolsSheetState();
}

class _ToolsSheetState extends ConsumerState<_ToolsSheet> {
  /// Which groups are open; kept while the app runs.
  static final _open = <String>{'features'};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatControllerProvider);
    final chat = ref.read(chatControllerProvider.notifier);
    final model = ref
        .watch(modelsProvider)
        .value
        ?.where((m) => m.id == state.modelId)
        .firstOrNull;
    final config = ref.watch(serverConfigProvider).value;
    final features = availableFeatures(model, config);
    final tools = ref.watch(toolsProvider).value ?? const <Pickable>[];
    final skills = ref.watch(skillsProvider).value ?? const <Pickable>[];
    final terminals = ref.watch(terminalServersProvider).value ?? const [];
    final activeTools = state.toolIds ?? model?.toolIds.toSet() ?? const {};
    final activeSkills = state.skillIds ?? const <String>{};
    final terminalId = state.terminalId ?? model?.terminalId ?? '';
    final terminal = terminals.where((t) => t.id == terminalId).firstOrNull;
    bool featureOn(String id) =>
        state.features[id] ?? model?.defaultFeatureIds.contains(id) ?? false;
    final muted = context.nexus.muted;
    final query = _query.trim().toLowerCase();
    bool matches(Pickable p) =>
        query.isEmpty ||
        p.name.toLowerCase().contains(query) ||
        (p.description ?? '').toLowerCase().contains(query);
    final searchable = tools.length + skills.length > 8;

    final onChips = [
      for (final id in features)
        if (featureOn(id))
          InputChip(
            avatar: Icon(_featureIcon(id), size: 16),
            label: Text(featureLabels[id] ?? id),
            onDeleted: () => chat.setFeature(id, false),
          ),
      if (terminal != null)
        InputChip(
          avatar: const Icon(Icons.terminal, size: 16),
          label: Text(terminal.name),
          onDeleted: () => chat.setTerminal(''),
        ),
      for (final t in tools)
        if (activeTools.contains(t.id))
          InputChip(
            avatar: const Icon(Icons.build_outlined, size: 16),
            label: Text(t.name),
            onDeleted: () => chat.setTool(t.id, false),
          ),
      for (final t in skills)
        if (activeSkills.contains(t.id))
          InputChip(
            avatar: const Icon(Icons.auto_awesome_outlined, size: 16),
            label: Text(t.name),
            onDeleted: () => chat.setSkill(t.id, false),
          ),
    ];

    Widget group({
      required String key,
      required IconData icon,
      required String title,
      required String summary,
      required List<Widget> children,
      Widget? action,
    }) {
      final open = query.isNotEmpty || _open.contains(key);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(summary),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ?action,
                Icon(open ? Icons.expand_less : Icons.expand_more),
              ],
            ),
            onTap: () => setState(
              () => _open.contains(key) ? _open.remove(key) : _open.add(key),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Column(children: children),
            ),
          const Divider(height: 1, indent: 16, endIndent: 16),
        ],
      );
    }

    Widget item(Pickable p, bool value, ValueChanged<bool> onChanged) =>
        SwitchListTile(
          dense: true,
          title: Text(p.name),
          subtitle: (p.description ?? '').isEmpty
              ? null
              : Text(
                  p.description!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          value: value,
          onChanged: onChanged,
        );

    final shownTools = tools.where(matches).toList();
    final shownSkills = skills.where(matches).toList();
    final toolsOn = tools.where((t) => activeTools.contains(t.id)).length;
    final skillsOn = skills.where((t) => activeSkills.contains(t.id)).length;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Tools for this chat',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (onChips.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Wrap(spacing: 6, runSpacing: 6, children: onChips),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Nothing extra is on.',
                  style: TextStyle(color: muted),
                ),
              ),
            if (searchable)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search tools and skills',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            if (features.isNotEmpty && query.isEmpty)
              group(
                key: 'features',
                icon: Icons.tune,
                title: 'Features',
                summary: _onOf(
                  features.where(featureOn).length,
                  features.length,
                ),
                children: [
                  for (final id in features)
                    SwitchListTile(
                      dense: true,
                      secondary: Icon(_featureIcon(id)),
                      title: Text(featureLabels[id] ?? id),
                      value: featureOn(id),
                      onChanged: (v) => chat.setFeature(id, v),
                    ),
                ],
              ),
            if (terminals.isNotEmpty && query.isEmpty)
              group(
                key: 'terminal',
                icon: Icons.terminal,
                title: 'Terminal',
                summary: terminal?.name ?? 'None',
                children: [
                  RadioGroup<String>(
                    groupValue: terminalId,
                    onChanged: (v) => chat.setTerminal(v ?? ''),
                    child: Column(
                      children: [
                        const RadioListTile<String>(
                          dense: true,
                          value: '',
                          title: Text('No terminal'),
                        ),
                        for (final t in terminals)
                          RadioListTile<String>(
                            dense: true,
                            value: t.id,
                            title: Text(t.name),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            if (shownTools.isNotEmpty)
              group(
                key: 'tools',
                icon: Icons.build_outlined,
                title: 'Tools',
                summary: _onOf(toolsOn, tools.length),
                action: toolsOn == 0
                    ? null
                    : TextButton(
                        onPressed: () {
                          for (final t in tools) {
                            if (activeTools.contains(t.id)) {
                              chat.setTool(t.id, false);
                            }
                          }
                        },
                        child: const Text('All off'),
                      ),
                children: [
                  for (final t in shownTools)
                    item(
                      t,
                      activeTools.contains(t.id),
                      (v) => chat.setTool(t.id, v),
                    ),
                ],
              ),
            if (shownSkills.isNotEmpty)
              group(
                key: 'skills',
                icon: Icons.auto_awesome_outlined,
                title: 'Skills',
                summary: _onOf(skillsOn, skills.length),
                action: skillsOn == 0
                    ? null
                    : TextButton(
                        onPressed: () {
                          for (final t in skills) {
                            if (activeSkills.contains(t.id)) {
                              chat.setSkill(t.id, false);
                            }
                          }
                        },
                        child: const Text('All off'),
                      ),
                children: [
                  for (final t in shownSkills)
                    item(
                      t,
                      activeSkills.contains(t.id),
                      (v) => chat.setSkill(t.id, v),
                    ),
                ],
              ),
            if (query.isNotEmpty && shownTools.isEmpty && shownSkills.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Nothing matches "$_query".',
                  style: TextStyle(color: muted),
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

IconData _featureIcon(String id) => switch (id) {
  'web_search' => Icons.language,
  'image_generation' => Icons.image_outlined,
  _ => Icons.code,
};

String _onOf(int on, int all) => on == 0 ? '$all available' : '$on of $all on';
