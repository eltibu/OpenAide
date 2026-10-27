import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/widgets/nexus_logo.dart';
import 'sso_login_screen.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _url = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _apiKey = TextEditingController();
  bool _useApiKey = false;

  @override
  void dispose() {
    for (final c in [_url, _email, _password, _apiKey]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final notifier = ref.read(sessionProvider.notifier);
    if (_useApiKey) {
      notifier.signInWithApiKey(_url.text, _apiKey.text);
    } else {
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
    return Scaffold(
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
                  'Nexus Assistant',
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
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Email')),
                    ButtonSegment(value: true, label: Text('API key')),
                  ],
                  selected: {_useApiKey},
                  onSelectionChanged: (s) =>
                      setState(() => _useApiKey = s.first),
                ),
                const SizedBox(height: 16),
                if (_useApiKey)
                  TextField(
                    controller: _apiKey,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API key (Settings → Account)',
                      border: OutlineInputBorder(),
                    ),
                  )
                else ...[
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
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
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: session.isLoading ? null : _submit,
                  child: session.isLoading
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Connect'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
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
                if (session.hasError) ...[
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
  }
}
