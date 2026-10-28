/// Settings > Account extras: your status and your keys for the API.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../chat/chat_controller.dart' show serverConfigProvider;
import 'settings_screen.dart' show meProvider, settingsApiProvider;

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

bool _feature(WidgetRef ref, String key) =>
    ((ref.watch(serverConfigProvider).value?['features'] as Map?)?[key]) ==
    true;

/// The status beside your name in channels and on the web, as in the
/// web's account menu.
class AccountStatus extends ConsumerWidget {
  const AccountStatus({super.key});

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> me,
  ) async {
    final emoji = TextEditingController(text: '${me['status_emoji'] ?? ''}');
    final message = TextEditingController(
      text: '${me['status_message'] ?? ''}',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Update your status'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 56,
                  child: TextField(
                    controller: emoji,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(hintText: '🙂'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: message,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'What\'s your status?',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _save(
      context,
      ref,
      emoji: emoji.text.trim(),
      message: message.text.trim(),
    );
  }

  Future<void> _save(
    BuildContext context,
    WidgetRef ref, {
    String emoji = '',
    String message = '',
  }) async {
    try {
      await ref
          .read(settingsApiProvider)
          .setStatus(emoji: emoji, message: message);
      ref.invalidate(meProvider);
    } catch (e) {
      if (context.mounted) _say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_feature(ref, 'enable_user_status')) return const SizedBox.shrink();
    final me = ref.watch(meProvider).value ?? const {};
    final set =
        '${me['status_message'] ?? ''}'.isNotEmpty ||
        '${me['status_emoji'] ?? ''}'.isNotEmpty;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Text(
        '${me['status_emoji'] ?? ''}'.isEmpty ? '💬' : '${me['status_emoji']}',
        style: const TextStyle(fontSize: 22),
      ),
      title: const Text('Status'),
      subtitle: Text(
        set ? '${me['status_message'] ?? ''}' : 'Update your status',
      ),
      onTap: () => _edit(context, ref, me),
      trailing: set
          ? IconButton(
              tooltip: 'Clear status',
              icon: const Icon(Icons.close),
              onPressed: () => _save(context, ref),
            )
          : null,
    );
  }
}

/// Your sign-in token and API key, for scripts and other apps.
class ApiKeys extends ConsumerStatefulWidget {
  const ApiKeys({super.key});

  @override
  ConsumerState<ApiKeys> createState() => _ApiKeysState();
}

class _ApiKeysState extends ConsumerState<ApiKeys> {
  String? _key;
  bool _loaded = false;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    ref
        .read(settingsApiProvider)
        .apiKey()
        .then((k) => _key = k, onError: (_) => null)
        .whenComplete(() {
          if (mounted) setState(() => _loaded = true);
        });
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _say(context, '$what copied');
  }

  Future<void> _create() async {
    if (_key != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Make a new key?'),
          content: const Text(
            'The old key stops working, so anything using it needs the new '
            'one.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Make new key'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      final key = await ref.read(settingsApiProvider).createApiKey();
      setState(() {
        _key = key;
        _show = true;
      });
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  Future<void> _delete() async {
    try {
      await ref.read(settingsApiProvider).deleteApiKey();
      setState(() => _key = null);
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final token = '${ref.watch(meProvider).value?['token'] ?? ''}';
    final keysOn = _feature(ref, 'enable_api_keys');
    String hide(String s) => s.length <= 8
        ? '••••'
        : '${s.substring(0, 6)}••••${s.substring(s.length - 4)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('API keys', style: Theme.of(context).textTheme.titleSmall),
        if (token.isNotEmpty)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('JWT token'),
            subtitle: Text(
              '${hide(token)} · ends when you sign out',
              style: TextStyle(color: muted),
            ),
            trailing: IconButton(
              tooltip: 'Copy token',
              icon: const Icon(Icons.copy),
              onPressed: () => _copy(token, 'Token'),
            ),
          ),
        if (!keysOn)
          Text(
            'API keys are off on this server. An admin can turn them on in '
            'Admin Panel > General.',
            style: TextStyle(color: muted),
          )
        else if (!_loaded)
          const LinearProgressIndicator()
        else if (_key == null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.key),
              label: const Text('Create new secret key'),
            ),
          )
        else
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('API key'),
            subtitle: SelectableText(
              _show ? _key! : hide(_key!),
              style: TextStyle(color: muted),
            ),
            onTap: () => setState(() => _show = !_show),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Copy API key',
                  icon: const Icon(Icons.copy),
                  onPressed: () => _copy(_key!, 'API key'),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) => v == 'new' ? _create() : _delete(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'new', child: Text('Create new key')),
                    PopupMenuItem(value: 'delete', child: Text('Delete key')),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
