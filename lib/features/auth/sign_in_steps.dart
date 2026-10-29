/// What can come between typing a password and being signed in: two-step
/// sign-in (set up an authenticator, enter its code, or use a reset token)
/// and an account an admin hasn't approved yet.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/widgets/nexus_logo.dart';
import '../../core/i18n/app_strings.dart';

/// Recovery codes as a text file, one per line.
String recoveryCodesFile(List<String> codes) =>
    'Open WebUI recovery codes\n'
    'Each code works once. Keep them somewhere safe.\n\n'
    '${codes.join('\n')}\n';

/// Saves recovery codes where the user picks.
Future<void> downloadRecoveryCodes(
  BuildContext context,
  List<String> codes,
) async {
  final saved = await FilePicker.saveFile(
    fileName: 'recovery-codes.txt',
    bytes: Uint8List.fromList(utf8.encode(recoveryCodesFile(codes))),
  );
  if (saved != null && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: T('Recovery codes saved')));
  }
}

Widget _page(BuildContext context, List<Widget> children) => Scaffold(
  body: SafeArea(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: ListView(
          padding: const EdgeInsets.all(24),
          shrinkWrap: true,
          children: [
            const Center(child: NexusLogo(size: 72)),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    ),
  ),
);

/// Waiting for an admin to approve the account.
class PendingScreen extends ConsumerWidget {
  const PendingScreen({
    super.key,
    required this.onCheck,
    this.busy = false,
    this.signedIn = false,
  });
  final VoidCallback onCheck;
  final bool busy;

  /// Already signed in (as a pending user), so Sign out rather than back.
  final bool signedIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return _page(context, [
      T(
        'Account Activation Pending',
        textAlign: TextAlign.center,
        style: theme.textTheme.headlineSmall,
      ),
      const SizedBox(height: 12),
      const T(
        'Contact your admin for access. You can use the app once they '
        'approve your account.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: busy ? null : onCheck,
        child: const T('Check Again'),
      ),
      TextButton(
        onPressed: () => signedIn
            ? ref.read(sessionProvider.notifier).signOut()
            : ref.read(sessionProvider.notifier).restart(),
        child: Text(signedIn ? 'Sign Out' : 'Back to sign in'),
      ),
    ]);
  }
}

class TwoStepScreen extends ConsumerStatefulWidget {
  const TwoStepScreen({super.key, required this.step, this.busy = false});
  final SignInStep step;
  final bool busy;

  @override
  ConsumerState<TwoStepScreen> createState() => _TwoStepScreenState();
}

class _TwoStepScreenState extends ConsumerState<TwoStepScreen> {
  final _code = TextEditingController();
  Map<String, dynamic>? _setup;
  Object? _setupError;
  bool _recovery = false;
  bool _busy = false;
  String? _shownFor;

  SignInStep get _step => widget.step;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadSetup();
  }

  @override
  void didUpdateWidget(TwoStepScreen old) {
    super.didUpdateWidget(old);
    _loadSetup();
  }

  /// The authenticator's key and QR code, once per challenge.
  Future<void> _loadSetup() async {
    if (_step.next != 'enroll' || _shownFor == _step.challenge) return;
    _shownFor = _step.challenge;
    _setup = null;
    _setupError = null;
    try {
      final res = await _step.client.send(
        'POST',
        '/api/v1/auths/mfa/enroll/start',
        body: {'challenge_token': _step.challenge},
      );
      _setup = (res as Map).cast<String, dynamic>();
    } catch (e) {
      _setupError = e;
    }
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() => _busy = true);
    await ref
        .read(sessionProvider.notifier)
        .answerStep(_step, code, recovery: _recovery);
    if (!mounted) return;
    _code.clear();
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final busy = _busy || widget.busy;
    if (_step.next == 'codes') {
      final codes = _step.recoveryCodes;
      return _page(context, [
        T(
          'Recovery codes',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        T(
          'Each code signs you in once if you lose your authenticator. '
          'They are shown only now.',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 16),
        SelectableText(
          codes.join('\n'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.copy),
                label: const T('Copy'),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: codes.join('\n'))),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.download),
                label: const T('Download'),
                onPressed: () => downloadRecoveryCodes(context, codes),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy
              ? null
              : () => ref.read(sessionProvider.notifier).finishStep(_step),
          child: const T('Continue'),
        ),
      ]);
    }
    final enroll = _step.next == 'enroll';
    final recover = _step.next == 'recover';
    final setup = _setup;
    return _page(context, [
      Text(
        enroll
            ? 'Set up two-step sign-in'
            : recover
            ? 'Reset two-step sign-in'
            : 'Two-step sign-in',
        textAlign: TextAlign.center,
        style: theme.textTheme.headlineSmall,
      ),
      const SizedBox(height: 8),
      Text(
        enroll
            ? 'Scan this with an authenticator app, or type the key into it, '
                  'then enter the 6-digit code it shows.'
            : recover
            ? 'Enter the reset token your admin gave you.'
            : _recovery
            ? 'Enter one of your recovery codes.'
            : 'Enter the 6-digit code from your authenticator app.',
        textAlign: TextAlign.center,
        style: TextStyle(color: muted),
      ),
      if (enroll) ...[
        const SizedBox(height: 16),
        if (_setupError != null) ...[
          Text(
            "Couldn't start the setup.\n$_setupError",
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error),
          ),
          TextButton(
            onPressed: () {
              _shownFor = null;
              _loadSetup();
            },
            child: const T('Retry setup'),
          ),
        ] else if (setup == null)
          const Center(child: CircularProgressIndicator())
        else ...[
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
            label: const T('Copy key'),
            onPressed: () => Clipboard.setData(
              ClipboardData(text: '${setup['manual_key'] ?? ''}'),
            ),
          ),
        ],
      ],
      if (_step.reply['error'] != null) ...[
        const SizedBox(height: 12),
        Text(
          '${_step.reply['error']}',
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      ],
      const SizedBox(height: 16),
      TextField(
        controller: _code,
        autofocus: !enroll,
        keyboardType: recover || _recovery
            ? TextInputType.text
            : TextInputType.number,
        maxLength: recover ? 160 : (_recovery ? 128 : 6),
        onSubmitted: (_) => _send(),
        decoration: InputDecoration(
          labelText: recover
              ? 'Reset token'
              : _recovery
              ? 'Recovery code'
              : 'Code',
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: busy || (enroll && setup == null) ? null : _send,
        child: busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const T('Continue'),
      ),
      if (_step.next == 'verify')
        TextButton(
          onPressed: () => setState(() => _recovery = !_recovery),
          child: Text(
            _recovery ? 'Use your authenticator app' : 'Use a recovery code',
          ),
        ),
      TextButton(
        onPressed: () => ref.read(sessionProvider.notifier).restart(),
        child: const T('Sign in again'),
      ),
    ]);
  }
}

/// The server's QR code is an SVG, which a web view draws.
class SetupQrCode extends StatefulWidget {
  const SetupQrCode({super.key, required this.dataUrl});
  final String dataUrl;

  @override
  State<SetupQrCode> createState() => _SetupQrCodeState();
}

class _SetupQrCodeState extends State<SetupQrCode> {
  late final _web = WebViewController()
    ..setBackgroundColor(Colors.white)
    ..loadHtmlString(
      '<html><body style="margin:0;background:#fff">'
      '<img src="${const HtmlEscape().convert(widget.dataUrl)}" '
      'style="width:100%;height:100%"></body></html>',
    );

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: 200, child: WebViewWidget(controller: _web));
}
