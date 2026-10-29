/// Settings > Account extras: your status and your keys for the API.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../../core/widgets/hideable.dart';
import '../chat/chat_controller.dart' show serverConfigProvider;
import 'settings_screen.dart' show meProvider, settingsApiProvider;
import '../../core/i18n/app_strings.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(text))));

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
        title: const T('Update your status'),
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
                    decoration: InputDecoration(hintText: tr('🙂')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: message,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: tr('What\'s your status?'),
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
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const T('Save'),
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
      title: const T('Status'),
      subtitle: Text(
        set ? '${me['status_message'] ?? ''}' : 'Update your status',
      ),
      onTap: () => _edit(context, ref, me),
      trailing: set
          ? IconButton(
              tooltip: tr('Clear status'),
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
          title: const T('Make a new key?'),
          content: const T(
            'The old key stops working, so anything using it needs the new '
            'one.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const T('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const T('Make new key'),
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
        T('API keys', style: Theme.of(context).textTheme.titleSmall),
        if (token.isNotEmpty)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const T('JWT token'),
            subtitle: Text(
              '${hide(token)} · ends when you sign out',
              style: TextStyle(color: muted),
            ),
            trailing: IconButton(
              tooltip: tr('Copy token'),
              icon: const Icon(Icons.copy),
              onPressed: () => _copy(token, 'Token'),
            ),
          ),
        if (!keysOn)
          T(
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
              label: const T('Create new secret key'),
            ),
          )
        else
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const T('API key'),
            subtitle: SelectableText(
              _show ? _key! : hide(_key!),
              style: TextStyle(color: muted),
            ),
            onTap: () => setState(() => _show = !_show),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: tr('Copy API key'),
                  icon: const Icon(Icons.copy),
                  onPressed: () => _copy(_key!, 'API key'),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) => v == 'new' ? _create() : _delete(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'new', child: T('Create new key')),
                    PopupMenuItem(value: 'delete', child: T('Delete key')),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Change Password, as on the web's Account tab (only when the server has
/// the password form on). The server signs out every device when it
/// changes, so this phone signs straight back in with the new one.
class ChangePassword extends ConsumerStatefulWidget {
  const ChangePassword({super.key});

  @override
  ConsumerState<ChangePassword> createState() => _ChangePasswordState();
}

class _ChangePasswordState extends ConsumerState<ChangePassword> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _open = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_current, _next, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _update() async {
    if (_next.text != _confirm.text) {
      _say(
        context,
        "The passwords you entered don't quite match. Please double-check "
        'and try again.',
      );
      return;
    }
    if (_next.text.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const T('Change your password?'),
        content: const T(
          'The server signs you out on every device when your password '
          'changes. This phone signs back in by itself; your other devices '
          'and the web need the new password.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const T('Update password'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final client = ref.read(clientProvider);
    final email = '${ref.read(meProvider).value?['email'] ?? ''}';
    try {
      await ref.read(settingsApiProvider).updatePassword(
        _current.text,
        _next.text,
      );
    } catch (e) {
      if (mounted) {
        _say(context, '$e');
        setState(() => _busy = false);
      }
      return;
    }
    // Still signed in? If the server ended this session, sign in again.
    try {
      await client.me();
    } catch (_) {
      if (email.isNotEmpty) {
        await ref
            .read(sessionProvider.notifier)
            .signInWithPassword(client.baseUrl, email, _next.text);
      }
    }
    if (!mounted) return;
    _say(context, 'Password updated.');
    for (final c in [_current, _next, _confirm]) {
      c.clear();
    }
    setState(() {
      _busy = false;
      _open = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final features =
        (ref.watch(serverConfigProvider).value?['features'] as Map?) ??
        const {};
    if (features['enable_login_form'] == false ||
        features['enable_password_change_form'] == false) {
      return const SizedBox.shrink();
    }
    Widget field(TextEditingController c, String label) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Hideable(
        builder: (obscure, eye) => TextField(
          controller: c,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: tr(label), suffixIcon: eye),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.password),
          title: const T('Change Password'),
          trailing: Icon(_open ? Icons.expand_less : Icons.expand_more),
          onTap: () => setState(() => _open = !_open),
        ),
        if (_open) ...[
          field(_current, 'Current Password'),
          field(_next, 'New Password'),
          field(_confirm, 'Confirm Password'),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _busy ? null : _update,
              child: const T('Update password'),
            ),
          ),
        ],
      ],
    );
  }
}
