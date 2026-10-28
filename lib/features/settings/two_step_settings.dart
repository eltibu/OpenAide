/// Settings > Account: two-step sign-in, when the server asks for it. With a
/// fresh code you can get new recovery codes or move to a new authenticator.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../auth/sign_in_steps.dart';

const _base = '/api/v1/auths/mfa';

final twoStepStatusProvider = FutureProvider.autoDispose<Map<String, dynamic>?>(
  (ref) async {
    try {
      return ((await ref.watch(clientProvider).send('GET', '$_base/status'))
              as Map)
          .cast<String, dynamic>();
    } on ApiException {
      // Servers without two-step sign-in.
      return null;
    }
  },
);

/// Words under the setting.
String twoStepSummary(Map status) {
  if (status['enabled'] != true) return 'Managed by your administrator.';
  final left = status['recovery_codes_remaining'] ?? 0;
  return 'Authenticator configured. $left recovery codes remaining.';
}

/// The server asks for a recent sign-in before these changes.
bool needsFreshSignIn(Object error) =>
    '$error'.contains('reauthentication_required');

class TwoStepSettings extends ConsumerWidget {
  const TwoStepSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(twoStepStatusProvider).value;
    if (status == null || status['required'] != true) {
      return const SizedBox.shrink();
    }
    final enabled = status['enabled'] == true;
    return ListTile(
      leading: const Icon(Icons.verified_user_outlined),
      title: const Text('Multi-factor authentication'),
      subtitle: Text(
        twoStepSummary(status),
        style: TextStyle(color: context.nexus.muted),
      ),
      trailing: enabled ? const Icon(Icons.chevron_right) : null,
      onTap: enabled
          ? () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TwoStepManageScreen()),
            )
          : null,
    );
  }
}

class TwoStepManageScreen extends ConsumerStatefulWidget {
  const TwoStepManageScreen({super.key});

  @override
  ConsumerState<TwoStepManageScreen> createState() =>
      _TwoStepManageScreenState();
}

class _TwoStepManageScreenState extends ConsumerState<TwoStepManageScreen> {
  final _code = TextEditingController();
  bool _recovery = false;
  bool _busy = false;
  Object? _error;

  /// Set while moving to a new authenticator.
  String? _challenge;
  Map<String, dynamic>? _setup;

  /// Shown once, after new codes or a new authenticator.
  List<String>? _codes;

  OpenWebUiClient get _client => ref.read(clientProvider);

  Future<void> _run(Future<void> Function(String code) action) async {
    final code = _code.text.trim();
    if (code.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(code);
      _code.clear();
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _newCodes(String code) async {
    final res = await _client.send(
      'POST',
      '$_base/recovery/codes',
      body: {'code': code, 'recovery': _recovery},
    );
    _codes = [for (final c in (res as Map)['recovery_codes'] as List) '$c'];
  }

  Future<void> _replace(String code) async {
    final res = await _client.send(
      'POST',
      '$_base/replace',
      body: {'code': code, 'recovery': _recovery},
    );
    final challenge = '${(res as Map)['challenge_token']}';
    _setup = ((await _client.send(
      'POST',
      '$_base/enroll/start',
      body: {'challenge_token': challenge},
    )) as Map).cast<String, dynamic>();
    _challenge = challenge;
    _recovery = false;
  }

  Future<void> _confirm(String code) async {
    final res = await _client.send(
      'POST',
      '$_base/enroll/confirm',
      body: {'challenge_token': _challenge, 'code': code},
    );
    _codes = [for (final c in (res as Map)['recovery_codes'] as List) '$c'];
    _challenge = null;
  }

  /// The change signed every device out, this one too.
  Future<void> _done() async {
    final session = ref.read(sessionProvider.notifier);
    try {
      await _client.me();
      ref.invalidate(twoStepStatusProvider);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      await session.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = context.nexus.muted;
    final codes = _codes;
    final setup = _setup;
    final replacing = _challenge != null && setup != null;
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: const Text('Multi-factor authentication')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (codes != null) ...[
            Text('Recovery codes', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Each code signs you in once if you lose your authenticator. '
              'They are shown only now.',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 12),
            SelectableText(
              codes.join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy'),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: codes.join('\n'))),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('Download'),
                  onPressed: () => downloadRecoveryCodes(context, codes),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _done, child: const Text('Done')),
          ] else if (replacing) ...[
            Text(
              'Scan this with your new authenticator app, or type the key '
              'into it, then enter the 6-digit code it shows.',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 12),
            if ('${setup['qr_code'] ?? ''}'.startsWith('data:image/'))
              Center(child: SetupQrCode(dataUrl: '${setup['qr_code']}')),
            const SizedBox(height: 8),
            Center(
              child: SelectableText(
                '${setup['manual_key'] ?? ''}',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy key'),
              onPressed: () => Clipboard.setData(
                ClipboardData(text: '${setup['manual_key'] ?? ''}'),
              ),
            ),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              onSubmitted: (_) => _run(_confirm),
              decoration: const InputDecoration(
                labelText: 'Code',
                border: OutlineInputBorder(),
              ),
            ),
            FilledButton(
              onPressed: _busy ? null : () => _run(_confirm),
              child: const Text('Confirm'),
            ),
          ] else ...[
            Text(
              'Verify with a fresh code. Changes sign out all devices, this '
              'phone too.',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              keyboardType: _recovery
                  ? TextInputType.text
                  : TextInputType.number,
              maxLength: _recovery ? 128 : 6,
              decoration: InputDecoration(
                labelText: _recovery ? 'Recovery code' : 'Authenticator code',
                border: const OutlineInputBorder(),
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Use a recovery code'),
              value: _recovery,
              onChanged: (v) => setState(() {
                _recovery = v == true;
                _code.clear();
              }),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy ? null : () => _run(_replace),
                  child: const Text('Replace authenticator'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _run(_newCodes),
                  child: const Text('Generate recovery codes'),
                ),
              ],
            ),
          ],
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              needsFreshSignIn(error)
                  ? 'Sign in again before changing your authenticator '
                        'settings.'
                  : '$error',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            if (needsFreshSignIn(error))
              TextButton(
                onPressed: () => ref.read(sessionProvider.notifier).signOut(),
                child: const Text('Sign in again'),
              ),
          ],
        ],
      ),
    );
  }
}
