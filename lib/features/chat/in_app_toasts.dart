/// Toasts while the app is open, as on the web: a reply finished in another
/// chat, a message in a channel you aren't looking at, and calendar alerts.
/// A tap on Open goes there.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../calendar/calendar_screen.dart';
import '../channels/channels_api.dart';
import '../channels/channels_screen.dart';
import '../email/email_agent.dart'
    show appWorkingChats, emailChatKey, emailChatTitle;
import '../settings/about_screen.dart' show adminStartupNotes;
import 'chat_controller.dart';
import 'reply_notify.dart' show notificationText;

/// What a toast says and where Open goes.
sealed class Toast {
  const Toast(this.title, this.text);
  final String title;
  final String text;
}

class ReplyToast extends Toast {
  const ReplyToast(super.title, super.text, this.chatId);
  final String chatId;
}

class ChannelToast extends Toast {
  const ChannelToast(super.title, super.text, this.channelId);
  final String channelId;
}

class CalendarToast extends Toast {
  const CalendarToast(super.title, super.text);
}

/// The toast for a chat event, or null when there's nothing to say: only
/// finished replies in a chat other than [openChat].
Toast? chatEventToast(Map event, {String? openChat, String? hiddenChat}) {
  final inner = event['data'];
  if (inner is! Map) return null;
  final data = inner['data'];
  if (data is! Map) return null;
  if (inner['type'] == 'calendar:alert') {
    final minutes = (data['minutes_until'] as num?)?.toInt() ?? 0;
    return CalendarToast(
      '${data['title'] ?? 'Event'}',
      minutes <= 0
          ? 'Starting now'
          : minutes == 1
          ? 'Starting in 1 minute'
          : 'Starting in $minutes minutes',
    );
  }
  final chatId = '${event['chat_id'] ?? ''}';
  if (inner['type'] != 'chat:completion' || data['done'] != true) return null;
  if (chatId.isEmpty || chatId == openChat) return null;
  final title = '${data['title'] ?? ''}';
  // The app's own working chats (Email) aren't anyone's conversation.
  if (chatId == hiddenChat ||
      appWorkingChats.contains(chatId) ||
      title == emailChatTitle) {
    return null;
  }
  return ReplyToast(
    title.isEmpty ? 'New Chat' : title,
    notificationText('${data['content'] ?? ''}'),
    chatId,
  );
}

/// The toast for a channel event: new messages from others in channels not
/// on screen; a muted channel only when it mentions [me].
Toast? channelEventToast(
  Map event, {
  required String? me,
  required List<String> open,
  required bool Function(String channelId) muted,
}) {
  final inner = event['data'];
  if (inner is! Map || inner['type'] != 'message') return null;
  final data = inner['data'];
  if (data is! Map) return null;
  final channelId = '${event['channel_id'] ?? ''}';
  final user = data['user'] as Map? ?? const {};
  if (channelId.isEmpty || open.contains(channelId)) return null;
  if (me != null && user['id'] == me) return null;
  final content = '${data['content'] ?? ''}';
  if (muted(channelId) &&
      !RegExp(r'<@U:([^|>]+)(?:\|[^>]+)?>')
          .allMatches(content)
          .any((m) => m.group(1) == me)) {
    return null;
  }
  final channel = event['channel'] as Map? ?? const {};
  final name = '${user['name'] ?? 'Someone'}';
  return ChannelToast(
    channel['type'] == 'dm' ? name : '$name (#${channel['name'] ?? ''})',
    content.replaceAllMapped(
      RegExp(r'<([@#])([^|>\s]+)(?:\|([^>]*))?>'),
      (m) => '${m[1]}${m[3] ?? m[2]}',
    ),
    channelId,
  );
}

class InAppToasts extends ConsumerStatefulWidget {
  const InAppToasts({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<InAppToasts> createState() => _InAppToastsState();
}

class _InAppToastsState extends ConsumerState<InAppToasts> {
  final _subs = <StreamSubscription>[];

  @override
  void initState() {
    super.initState();
    try {
      final socket = ref.read(chatSocketProvider);
      _subs
        ..add(socket.events.listen(_onChat))
        ..add(socket.channelEvents.listen(_onChannel));
    } catch (_) {
      // Signed out.
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => mounted ? adminStartupNotes(context, ref) : null,
    );
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  void _onChat(Map<String, dynamic> e) {
    final state = ref.read(chatControllerProvider);
    // The web leaves temporary chats alone too.
    if (state.temporary) return;
    final ui = ref.read(userSettingsProvider).value?['ui'];
    final toast = chatEventToast(
      e,
      openChat: state.chat?.id,
      hiddenChat: ui is Map ? ui[emailChatKey] as String? : null,
    );
    if (toast != null) _show(toast);
  }

  void _onChannel(Map<String, dynamic> e) {
    final channels = ref.read(channelListProvider).value ?? const <Channel>[];
    final toast = channelEventToast(
      e,
      me: ref.read(sessionProvider).value?.user?['id'] as String?,
      open: openChannels,
      muted: (id) => channels.any((c) => c.id == id && c.muted),
    );
    if (toast != null) _show(toast);
  }

  void _show(Toast toast) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        // Above the message box, so typing and its buttons stay reachable.
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 96),
        dismissDirection: DismissDirection.horizontal,
        duration: Duration(seconds: toast is CalendarToast ? 30 : 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              toast.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (toast.text.isNotEmpty)
              Text(toast.text, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
        action: SnackBarAction(label: 'Open', onPressed: () => _open(toast)),
        showCloseIcon: true,
      ),
    );
  }

  Future<void> _open(Toast toast) async {
    final navigator = Navigator.of(context);
    switch (toast) {
      case ReplyToast(:final chatId):
        navigator.popUntil((r) => r.isFirst);
        await ref.read(chatControllerProvider.notifier).open(chatId);
      case CalendarToast():
        await navigator.push(
          MaterialPageRoute<void>(builder: (_) => const CalendarScreen()),
        );
      case ChannelToast(:final channelId):
        final listed = (ref.read(channelListProvider).value ?? const [])
            .where((c) => c.id == channelId)
            .firstOrNull;
        try {
          final channel =
              listed ?? await ref.read(channelsApiProvider).get(channelId);
          await navigator.push(
            MaterialPageRoute<void>(
              builder: (_) => ChannelScreen(channel: channel),
            ),
          );
        } catch (_) {
          // Gone or no longer yours.
        }
    }
  }
}
