/// The web UI's chat panel: Controls, Files and Overview tabs beside the
/// chat on a wide screen, or as a drawer from the right on a phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../../core/theme.dart';
import '../settings/settings_screen.dart' show Avatar, meProvider;
import '../terminal/terminal_api.dart' show TerminalServer;
import '../terminal/terminal_screen.dart'
    show TerminalScreen, allTerminalsProvider;
import 'chat_controller.dart';
import 'chat_controls.dart';
import 'side_panel.dart';
import '../../core/i18n/app_strings.dart';

/// What the chat's drawer should show: a tab, and for Files which terminal,
/// whether the shell or the files, and a file to open. [nonce] changes on
/// each request, so asking again (another file) refreshes it.
class PanelRequest {
  const PanelRequest({
    this.tab = 0,
    this.serverId,
    this.files = true,
    this.openPath,
    this.openIsDir = false,
    this.nonce = 0,
  });
  final int tab;
  final String? serverId;
  final bool files;
  final String? openPath;
  final bool openIsDir;
  final int nonce;
}

class _PanelRequests extends Notifier<PanelRequest> {
  @override
  PanelRequest build() => const PanelRequest();

  void set(PanelRequest r) => state = PanelRequest(
    tab: r.tab,
    serverId: r.serverId,
    files: r.files,
    openPath: r.openPath,
    openIsDir: r.openIsDir,
    nonce: state.nonce + 1,
  );
}

final panelRequestProvider = NotifierProvider<_PanelRequests, PanelRequest>(
  _PanelRequests.new,
);

/// Opens the chat's drawer on [tab] (0 Controls, 1 Files, 2 Overview):
/// beside the chat on a wide screen, sliding in from the right on a phone.
/// For Files, [serverId] picks the terminal (else the chat's, else the
/// first), [files] false shows its shell, and [openPath] a file to open.
void showChatPanel(
  BuildContext context, {
  int tab = 0,
  String? serverId,
  bool files = true,
  String? openPath,
  bool openIsDir = false,
}) {
  ProviderScope.containerOf(context, listen: false)
      .read(panelRequestProvider.notifier)
      .set(
        PanelRequest(
          tab: tab,
          serverId: serverId,
          files: files,
          openPath: openPath,
          openIsDir: openIsDir,
        ),
      );
  final host = SidePanelHost.maybeOf(context);
  if (host != null) {
    host.open(SidePanelContent('chatPanel', (_) => const ChatPanel()));
    return;
  }
  final scaffold = Scaffold.maybeOf(context);
  if (scaffold != null && scaffold.hasEndDrawer) {
    scaffold.openEndDrawer();
    return;
  }
  Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => const ChatPanel()),
  );
}

class ChatPanel extends ConsumerStatefulWidget {
  const ChatPanel({super.key});

  @override
  ConsumerState<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends ConsumerState<ChatPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: ref.read(panelRequestProvider).tab,
  );

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _close() {
    final panel = InSidePanel.maybeOf(context);
    if (panel != null) return panel.close();
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold != null && scaffold.isEndDrawerOpen) {
      return scaffold.closeEndDrawer();
    }
    Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(panelRequestProvider, (_, r) => _tabs.animateTo(r.tab));
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 8,
        centerTitle: false,
        title: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          dividerHeight: 0,
          labelPadding: const EdgeInsets.symmetric(horizontal: 12),
          tabs: const [
            Tab(text: 'Controls', height: 36),
            Tab(text: 'Files', height: 36),
            Tab(text: 'Overview', height: 36),
          ],
        ),
        actions: [
          IconButton(
            tooltip: tr('Close'),
            icon: const Icon(Icons.close),
            onPressed: _close,
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        physics: const NeverScrollableScrollPhysics(),
        children: const [
          ChatControlsView(inPanel: true),
          _Files(),
          _Overview(),
        ],
      ),
    );
  }
}

/// The terminal's shell and files, as the web's Files tab: the one picked,
/// the chat's, or the first there is, with a switch when there are several.
class _Files extends ConsumerWidget {
  const _Files();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(allTerminalsProvider);
    final request = ref.watch(panelRequestProvider);
    final chosen = ref.watch(
      chatControllerProvider.select((s) => s.terminalId),
    );
    final list = servers.value ?? const <TerminalServer>[];
    if (servers.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (list.isEmpty) {
      return const _Empty(
        icon: Icons.folder_off_outlined,
        text: 'No terminal on this server, so there are no files to show.',
      );
    }
    final server =
        list.where((s) => s.id == request.serverId).firstOrNull ??
        list.where((s) => s.id == chosen).firstOrNull ??
        list.first;
    return Column(
      children: [
        if (list.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            child: DropdownButton<String>(
              value: server.id,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final s in list)
                  DropdownMenuItem(
                    value: s.id,
                    child: Row(
                      children: [
                        Icon(
                          Icons.cloud_outlined,
                          size: 18,
                          color: context.nexus.muted,
                        ),
                        const SizedBox(width: 8),
                        Text(s.name),
                      ],
                    ),
                  ),
              ],
              onChanged: (id) => ref
                  .read(panelRequestProvider.notifier)
                  .set(PanelRequest(tab: 1, serverId: id)),
            ),
          ),
        Expanded(
          child: TerminalScreen(
            key: ValueKey((server.id, request.nonce)),
            server: server,
            startInFiles: request.files,
            openPath: request.serverId == null || request.serverId == server.id
                ? request.openPath
                : null,
            openIsDir: request.openIsDir,
            embedded: true,
            onAskFile: (message, bytes, name) async {
              final chat = ref.read(chatControllerProvider.notifier);
              await chat.attach(bytes, name);
              if (!await chat.send(message)) throw 'The chat is busy';
            },
          ),
        ),
      ],
    );
  }
}

/// Every message in the chat as a tree, as the web's Overview draws it:
/// the shown conversation is highlighted, and tapping another branch shows
/// that one.
class _Overview extends ConsumerWidget {
  const _Overview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatControllerProvider);
    final chat = state.chat;
    if (chat == null || chat.messages.isEmpty) {
      return const _Empty(
        icon: Icons.account_tree_outlined,
        text: 'Messages show here as a map once the chat starts.',
      );
    }
    final shown = {for (final m in state.messages) m.id};
    final names = {
      for (final m in ref.watch(modelsProvider).value ?? const []) m.id: m.name,
    };
    // Depth-first; a level of indent only where a message has alternatives.
    final rows = <(ChatMessage, int)>[];
    void walk(List<String> ids, int depth) {
      final branch = ids.length > 1;
      for (final id in ids) {
        final m = chat.messages[id];
        if (m == null) continue;
        rows.add((m, depth));
        walk(m.childrenIds, branch ? depth + 1 : depth);
      }
    }

    final roots = [
      for (final m in chat.messages.values)
        if (m.parentId == null || !chat.messages.containsKey(m.parentId)) m,
    ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    walk([for (final r in roots) r.id], 0);
    final me =
        ref.watch(meProvider).value ?? ref.watch(sessionProvider).value?.user;
    // Settings > Interface > Show your name.
    final showName =
        (ref.watch(userSettingsProvider).value?['ui']
            as Map?)?['showUsername'] ==
        true;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final (m, depth) = rows[i];
        return Padding(
          padding: EdgeInsets.only(left: 16.0 * depth),
          child: _Node(
            message: m,
            name: m.role == 'user'
                ? (showName ? '${me?['name'] ?? 'You'}' : 'You')
                : names[m.model] ?? m.model ?? 'OpenAide',
            user: m.role == 'user' ? me : null,
            shown: shown.contains(m.id),
            last: i == rows.length - 1,
            onTap: state.streaming || shown.contains(m.id)
                ? null
                : () => ref.read(chatControllerProvider.notifier).showAnswer(m),
          ),
        );
      },
    );
  }
}

class _Node extends StatelessWidget {
  const _Node({
    required this.message,
    required this.name,
    required this.user,
    required this.shown,
    required this.last,
    this.onTap,
  });
  final ChatMessage message;
  final String name;
  final Map<String, dynamic>? user;
  final bool shown;
  final bool last;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = context.nexus.muted;
    final preview = message.content
        .replaceAll(RegExp(r'<details[\s\S]*?</details>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The thread line joining one message to the next.
          SizedBox(
            width: 12,
            child: Column(
              children: [
                const SizedBox(height: 18),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: shown ? NexusColors.accent : scheme.outline,
                  ),
                ),
                if (!last)
                  Expanded(
                    child: Container(width: 1, color: scheme.outlineVariant),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: shown
                    ? scheme.surfaceContainerHigh
                    : scheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: shown
                        ? NexusColors.accent.withValues(alpha: 0.5)
                        : scheme.outlineVariant,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (user != null)
                          Avatar(user: user, radius: 11)
                        else
                          const CircleAvatar(
                            radius: 11,
                            backgroundColor: NexusColors.accent,
                            child: Icon(
                              Icons.auto_awesome,
                              size: 12,
                              color: Colors.white,
                            ),
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelLarge,
                              ),
                              if (preview.isNotEmpty)
                                Text(
                                  preview,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: muted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 32, color: context.nexus.muted),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.nexus.muted),
          ),
        ],
      ),
    ),
  );
}
