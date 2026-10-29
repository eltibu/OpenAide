/// An encrypted chat in a direct message or private group, as the web's:
/// sealed on this phone, relayed by the server, never saved. Leaving the
/// screen leaves the chat and clears it from this phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme.dart';
import '../settings/settings_screen.dart' show meProvider;
import 'encrypted_conversation.dart';

class EncryptedChatScreen extends ConsumerStatefulWidget {
  /// Starts one in [channel], or joins [session].
  const EncryptedChatScreen({
    super.key,
    required this.channel,
    required this.title,
    this.session,
  });
  final String channel;
  final String title;
  final String? session;

  @override
  ConsumerState<EncryptedChatScreen> createState() => _EncryptedChatState();
}

class _EncryptedChatState extends ConsumerState<EncryptedChatScreen> {
  EncryptedConversation? _chat;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// Fingerprints you checked with the person ("Codes match"), for now.
  final _verified = <String>{};

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final me = await ref.read(meProvider.future);
    if (!mounted) return;
    setState(() {
      _chat = EncryptedConversation(
        SocketRelay(ref.read(chatSocketProvider)),
        channel: widget.channel,
        user: '${me['id']}',
        session: widget.session,
      )..addListener(_changed);
    });
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _chat
      ?..removeListener(_changed)
      ..dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    if (text.length > 16384) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: T('Message exceeds the 16 KiB limit.')));
      return;
    }
    _input.clear();
    _chat?.sendText(text);
  }

  void _people() {
    final chat = _chat;
    if (chat == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              T('Participants', style: Theme.of(context).textTheme.titleMedium),
              T(
                'Compare these codes with each person, in person or on a '
                'call. When they match, nobody is in between.',
                style: TextStyle(color: context.nexus.muted),
              ),
              const SizedBox(height: 8),
              for (final m in chat.members)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                m.participation == chat.self
                                    ? '${m.name} (${tr('you')})'
                                    : m.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (_verified.contains(m.fingerprint))
                              Chip(
                                avatar: const Icon(Icons.verified, size: 16),
                                label: const T('Verified'),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        SelectableText(
                          RegExp(r'.{1,4}')
                              .allMatches(m.fingerprint)
                              .map((x) => x.group(0))
                              .join(' '),
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        if (m.participation != chat.self &&
                            !_verified.contains(m.fingerprint))
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () {
                                setState(() => _verified.add(m.fingerprint));
                                setSheet(() {});
                              },
                              child: const T('Codes match'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chat = _chat;
    final status = chat?.status ?? EncryptedStatus.joining;
    final muted = context.nexus.muted;
    final scheme = Theme.of(context).colorScheme;
    final typing = [
      for (final t in chat?.typing ?? const <String>[]) chat!.nameOf(t),
    ];
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: tr('Leave'),
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          children: [
            const T('Encrypted chat'),
            Text(
              widget.title,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: muted),
            ),
          ],
        ),
        actions: [
          if (status == EncryptedStatus.active) ...[
            IconButton(
              tooltip: tr('Participants'),
              icon: Badge(
                label: Text('${chat!.members.length}'),
                child: const Icon(Icons.people_outline),
              ),
              onPressed: _people,
            ),
            IconButton(
              tooltip: tr('Refresh encryption keys'),
              icon: const Icon(Icons.key_outlined),
              onPressed: () {
                chat.updateKeys();
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: T('Refresh encryption keys')));
              },
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              color: scheme.surfaceContainerHigh,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.lock_outline, size: 16, color: muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: T(
                      'Messages are end-to-end encrypted and aren’t saved. '
                      'Leaving clears this phone’s chat.',
                      style: TextStyle(color: muted, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: switch (status) {
                EncryptedStatus.joining => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      T(
                        'Joining encrypted chat…',
                        style: TextStyle(color: muted),
                      ),
                    ],
                  ),
                ),
                EncryptedStatus.ended => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_clock_outlined, size: 40, color: muted),
                      const SizedBox(height: 12),
                      const T('Encrypted chat ended'),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const T('Return to conversation'),
                      ),
                    ],
                  ),
                ),
                EncryptedStatus.active => ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final m in chat!.messages)
                      if (m.joined)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Center(
                            child: Text(
                              tr(
                                '{{NAME}} joined',
                              ).replaceAll('{{NAME}}', chat.nameOf(m.sender)),
                              style: TextStyle(color: muted, fontSize: 12.5),
                            ),
                          ),
                        )
                      else
                        _Bubble(message: m, mine: m.sender == chat.self),
                  ],
                ),
              },
            ),
            if (typing.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${typing.join(', ')} '
                    '${tr(typing.length == 1 ? 'is typing...' : 'are typing...')}',
                    style: TextStyle(color: muted, fontSize: 12.5),
                  ),
                ),
              ),
            if (status == EncryptedStatus.active)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 5,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: tr('Type here...'),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          isDense: true,
                        ),
                        onChanged: (v) => chat?.sendTyping(v.isNotEmpty),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    IconButton(
                      tooltip: tr('Send message'),
                      icon: const Icon(Icons.send),
                      color: NexusColors.accent,
                      onPressed: _send,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});
  final EncryptedMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final delivered =
        message.expected.isNotEmpty &&
        message.expected.every(message.received.contains);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: mine
                ? context.nexus.userBubble
                : Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!mine)
                Text(
                  message.userName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                  ),
                ),
              SelectableText(message.text),
              if (mine)
                Align(
                  alignment: Alignment.centerRight,
                  child: Tooltip(
                    message: tr(
                      !message.relayed
                          ? 'Sending…'
                          : delivered
                          ? 'Delivered'
                          : 'Encrypted',
                    ),
                    child: Icon(
                      !message.relayed
                          ? Icons.schedule
                          : delivered
                          ? Icons.done_all
                          : Icons.done,
                      size: 14,
                      color: muted,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
