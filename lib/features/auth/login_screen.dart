import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/net/local_network.dart';
import '../../core/widgets/nexus_logo.dart';
import 'sign_in_steps.dart';
import 'sso_login_screen.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/widgets/hideable.dart';

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

  /// The typed server has no accounts yet (the web's first-run welcome).
  bool _fresh = false;
  Timer? _lookup;

  @override
  void initState() {
    super.initState();
    _url.addListener(() {
      _lookup?.cancel();
      _lookup = Timer(const Duration(milliseconds: 700), _checkFresh);
    });
  }

  Future<void> _checkFresh() async {
    final typed = _url.text.trim();
    var fresh = false;
    if (typed.isNotEmpty) {
      try {
        final base = OpenWebUiClient.normalizeUrl(typed);
        final res = await http
            .get(Uri.parse('$base/api/config'))
            .timeout(const Duration(seconds: 8));
        fresh = serverIsFresh(res.statusCode == 200 ? res.body : null);
      } catch (_) {
        // Not reachable yet; the welcome only shows for a server that answers.
      }
    }
    if (mounted && typed == _url.text.trim() && fresh != _fresh) {
      setState(() => _fresh = fresh);
    }
  }

  @override
  void dispose() {
    _lookup?.cancel();
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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: T('Passwords do not match.')));
          return;
        }
        notifier.signUp(_url.text, _name.text, _email.text, _password.text);
      case _:
        notifier.signInWithPassword(_url.text, _email.text, _password.text);
    }
  }

  /// Plain http to an internet server: only once the person agrees.
  Future<bool> _okToSendUnencrypted(String host) async {
    final notifier = ref.read(sessionProvider.notifier);
    if (notifier.insecureOk.contains(host)) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const T('Connect without encryption?'),
        content: Text(
          '$host is reached over plain http. Your password, sign-in and '
          'chats would cross the internet unencrypted, and anyone on the '
          'way could read them. Use https:// if the server has it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const T('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const T('Connect anyway'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    notifier.insecureOk.add(host);
    return true;
  }

  Future<void> _allowAndRetry(InsecureServer e) async {
    if (await _okToSendUnencrypted(e.host)) _submit();
  }

  Future<void> _signInWithBrowser() async {
    if (_url.text.trim().isEmpty) return;
    final base = OpenWebUiClient.normalizeUrl(_url.text);
    final uri = Uri.parse(base);
    if (isInsecureRemote(uri) &&
        !await _okToSendUnencrypted(uri.host.toLowerCase())) {
      return;
    }
    if (!mounted) return;
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
                T(
                  'OpenAide',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                T(
                  'Connect to your Open WebUI server',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('Server URL'),
                    hintText: tr('https://openwebui.example.com'),
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_fresh && !_signUp) ...[
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          T(
                            'Welcome to Open WebUI',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          const T(
                            'This server has no accounts yet. The first '
                            'account you create becomes its admin.',
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: () => setState(() {
                              _mode = 'email';
                              _signUp = true;
                            }),
                            child: const T('Get started'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'email', label: T('Email')),
                    ButtonSegment(value: 'ldap', label: T('LDAP')),
                    ButtonSegment(value: 'key', label: T('API key')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
                const SizedBox(height: 16),
                if (_mode == 'key')
                  Hideable(
                    builder: (obscure, eye) => TextField(
                      controller: _apiKey,
                      obscureText: obscure,
                      decoration: InputDecoration(
                        suffixIcon: eye,
                        labelText: tr('API key (Settings → Account)'),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  )
                else ...[
                  if (_signUp && _mode == 'email') ...[
                    TextField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: tr('Name'),
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
                  Hideable(
                    builder: (obscure, eye) => TextField(
                      controller: _password,
                      obscureText: obscure,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        suffixIcon: eye,
                        labelText: tr('Password'),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  if (_signUp && _mode == 'email') ...[
                    const SizedBox(height: 12),
                    Hideable(
                      builder: (obscure, eye) => TextField(
                        controller: _confirm,
                        obscureText: obscure,
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          suffixIcon: eye,
                          labelText: tr('Confirm Password'),
                          border: OutlineInputBorder(),
                        ),
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
                  label: const T('Sign in with browser (SSO)'),
                ),
                const SizedBox(height: 4),
                T(
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
                  if (session.error case final InsecureServer e)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: session.isLoading
                            ? null
                            : () => _allowAndRetry(e),
                        child: const T('Connect anyway, unencrypted'),
                      ),
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

/// Whether a server's /api/config says it has no accounts yet.
bool serverIsFresh(String? configBody) {
  if (configBody == null) return false;
  try {
    final config = jsonDecode(configBody);
    return config is Map && config['onboarding'] == true;
  } catch (_) {
    return false;
  }
}
