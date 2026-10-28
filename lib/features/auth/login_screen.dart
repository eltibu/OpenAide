import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/widgets/nexus_logo.dart';
import 'sign_in_steps.dart';
import 'sso_login_screen.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.onBack});

  /// Back to the welcome screen, when it led here.
  final VoidCallback? onBack;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _url = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _apiKey = TextEditingController();
  final _name = TextEditingController();
  final _confirm = TextEditingController();

  /// email, ldap or key.
  String _mode = 'email';

  /// Creating an account instead of signing in.
  bool _signUp = false;

  @override
  void dispose() {
    for (final c in [_url, _email, _password, _apiKey, _name, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final notifier = ref.read(sessionProvider.notifier);
    switch (_mode) {
      case 'key':
        notifier.signInWithApiKey(_url.text, _apiKey.text);
      case 'ldap':
        notifier.signInWithLdap(_url.text, _email.text, _password.text);
      case _ when _signUp:
        if (_password.text != _confirm.text) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Passwords do not match.')),
          );
          return;
        }
        notifier.signUp(_url.text, _name.text, _email.text, _password.text);
      case _:
        notifier.signInWithPassword(_url.text, _email.text, _password.text);
    }
  }

  Future<void> _signInWithBrowser() async {
    if (_url.text.trim().isEmpty) return;
    final base = OpenWebUiClient.normalizeUrl(_url.text);
    final result = await Navigator.push<SsoResult>(
      context,
      MaterialPageRoute(builder: (_) => SsoLoginScreen(baseUrl: base)),
    );
    if (result == null) return;
    await ref
        .read(sessionProvider.notifier)
        .signInWithBrowser(base, result.token, result.cookie);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final theme = Theme.of(context);
    if (session.error case final SignInStep step) {
      return step.next == 'pending'
          ? PendingScreen(onCheck: _submit, busy: session.isLoading)
          : TwoStepScreen(step: step, busy: session.isLoading);
    }
    final scaffold = Scaffold(
      appBar: widget.onBack == null
          ? null
          : AppBar(leading: BackButton(onPressed: widget.onBack)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                const Center(child: NexusLogo(size: 96)),
                const SizedBox(height: 12),
                Text(
                  'OpenAide',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Connect to your Open WebUI server',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'https://openwebui.example.com',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'email', label: Text('Email')),
                    ButtonSegment(value: 'ldap', label: Text('LDAP')),
                    ButtonSegment(value: 'key', label: Text('API key')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
                const SizedBox(height: 16),
                if (_mode == 'key')
                  TextField(
                    controller: _apiKey,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API key (Settings → Account)',
                      border: OutlineInputBorder(),
                    ),
                  )
                else ...[
                  if (_signUp && _mode == 'email') ...[
                    TextField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _email,
                    keyboardType: _mode == 'ldap'
                        ? TextInputType.text
                        : TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: _mode == 'ldap' ? 'Username' : 'Email',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_signUp && _mode == 'email') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirm,
                      obscureText: true,
                      onSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(
                        labelText: 'Confirm Password',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 24),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: session.isLoading ? null : _submit,
                  child: session.isLoading
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _signUp && _mode == 'email'
                              ? 'Create Account'
                              : 'Connect',
                        ),
                ),
                if (_mode == 'email')
                  TextButton(
                    onPressed: () => setState(() => _signUp = !_signUp),
                    child: Text(
                      _signUp
                          ? 'Already have an account? Sign in'
                          : "Don't have an account? Sign up",
                    ),
                  ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: session.isLoading ? null : _signInWithBrowser,
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('Sign in with browser (SSO)'),
                ),
                const SizedBox(height: 4),
                Text(
                  'Use this for SSO, or when a login page sits in front of '
                  'Open WebUI.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
                if (session.hasError && session.error is! SignInStep) ...[
                  const SizedBox(height: 16),
                  Text(
                    '${session.error}',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (widget.onBack == null) return scaffold;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onBack!();
      },
      child: scaffold,
    );
  }
}
