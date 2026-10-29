/// The assistant as a panel over the app you're in, like the phone's own
/// assistant: long-press power or home, say or type a question, read the
/// answer, and go back to what you were doing. The chat is a normal one on
/// the server; Open in app carries on there. Settings > Phone and assistant
/// > Ask in a panel over other apps.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme.dart';
import '../../core/widgets/markdown_style.dart';
import '../chat/chat_controller.dart';
import '../studio/record_notes.dart' show dictate;
import 'app_lock.dart';
import 'phone_launch.dart';

/// The panel's own small app, run by AssistActivity (see assistMain).
class AssistPanelApp extends ConsumerWidget {
  const AssistPanelApp({super.key, this.listenFirst = true});

  /// Starts listening as it opens, as an assistant does.
  final bool listenFirst;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListenableBuilder(
    listenable: AppStrings.instance,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: nexusTheme(Brightness.light),
      darkTheme: nexusTheme(Brightness.dark),
      locale: AppStrings.instance.locale,
      // App lock covers the panel too: it reaches the same chats and phone
      // actions as the app.
      builder: (context, child) =>
          AppStringsScope(child: AppLockGate(holdChild: true, child: child!)),
      color: Colors.transparent,
      home: AssistPanel(listenFirst: listenFirst),
    ),
  );
}

class AssistPanel extends ConsumerStatefulWidget {
  const AssistPanel({super.key, this.listenFirst = true});
  final bool listenFirst;

  @override
  ConsumerState<AssistPanel> createState() => _AssistPanelState();
}

class _AssistPanelState extends ConsumerState<AssistPanel> {
  final _text = TextEditingController();
  bool _started = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Once signed in and a model is ready: a new chat, then listening.
  Future<void> _start() async {
    if (_started) return;
    _started = true;
    // Called from build: change the chat once this frame is drawn.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    ref.read(chatControllerProvider.notifier).newChat();
    if (widget.listenFirst) await _listen();
  }

  Future<void> _listen() async {
    final said = await dictate(context, ref.read(clientProvider));
    if (said != null && said.trim().isNotEmpty) await _send(said);
  }

  Future<void> _send(String text) async {
    final chat = ref.read(chatControllerProvider.notifier);
    // The model may still be loading the first time.
    for (var i = 0; i < 50 && !chat.canSend; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // Cleared as it goes; put back if it couldn't be sent.
    _text.clear();
    if (!await chat.send(text.trim()) && mounted) _text.text = text;
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final signedIn = session.value != null;
    if (signedIn) _start();
    final state = ref.watch(chatControllerProvider);
    // Ask your default model, as a new chat in the app does.
    final preferred = ref.watch(defaultModelProvider).value;
    if (state.modelId == null && preferred != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ref.read(chatControllerProvider).modelId == null) {
          ref.read(chatControllerProvider.notifier).selectModel(preferred);
        }
      });
    }
    final thread = state.chat?.thread ?? const [];
    final scheme = Theme.of(context).colorScheme;
    final muted = context.nexus.muted;
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          // A tap on the app behind closes the panel.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: closeAssistPanel,
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Material(
                color: scheme.surface,
                elevation: 8,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.7,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _header(state.chat?.id),
                      if (!signedIn && !session.isLoading)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                          child: T(
                            'Sign in to OpenAide first, then ask from here.',
                            style: TextStyle(color: muted),
                          ),
                        )
                      else if (thread.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                          child: T(
                            'Ask anything. Your chat is kept on your server.',
                            style: TextStyle(color: muted),
                          ),
                        )
                      else
                        Flexible(child: _answers(thread, state.status)),
                      if (state.error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            state.error!,
                            style: TextStyle(color: scheme.error),
                          ),
                        ),
                      if (signedIn) _composer(state.streaming),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(String? chatId) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
    child: Row(
      children: [
        Icon(Icons.auto_awesome, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'OpenAide',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
        TextButton.icon(
          icon: const Icon(Icons.open_in_full, size: 18),
          label: const T('Open in app'),
          onPressed: () => openAppFromPanel(
            chatId == null || chatId.isEmpty ? null : chatId,
          ),
        ),
        IconButton(
          tooltip: tr('Close'),
          icon: const Icon(Icons.close),
          onPressed: closeAssistPanel,
        ),
      ],
    ),
  );

  Widget _answers(List thread, String? status) {
    final muted = context.nexus.muted;
    return ListView(
      shrinkWrap: true,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      children: [
        for (final m in thread.reversed)
          if (m.role == 'user')
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(m.content),
              ),
            )
          else if ((m.content as String).trim().isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                status ?? tr('Thinking…'),
                style: TextStyle(color: muted),
              ),
            )
          else
            MarkdownBlock(
              data: m.content,
              selectable: true,
              config: nexusMarkdown(context),
            ),
      ],
    );
  }

  Widget _composer(bool streaming) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _text,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: tr('Ask OpenAide'),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            onSubmitted: (v) => _send(v),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: tr('Dictate'),
          icon: const Icon(Icons.mic_none),
          onPressed: streaming ? null : _listen,
        ),
        IconButton.filled(
          tooltip: tr('Send'),
          icon: const Icon(Icons.arrow_upward),
          onPressed: streaming ? null : () => _send(_text.text),
        ),
      ],
    ),
  );
}
