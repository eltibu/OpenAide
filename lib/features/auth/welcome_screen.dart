/// The first screen on a new phone: chat with an AI provider right away,
/// or connect an Open WebUI server.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../../core/widgets/nexus_logo.dart';
import '../standalone/local_chats.dart';
import 'login_screen.dart';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  /// Null while checking; true shows the server sign-in.
  bool? _server;

  @override
  void initState() {
    super.initState();
    // Someone who used a server before goes straight back to its sign-in.
    hasSavedServer().then((saved) {
      if (mounted) setState(() => _server ??= saved);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_server == true) {
      return LoginScreen(onBack: () => setState(() => _server = false));
    }
    if (_server == null) return const Scaffold();
    final theme = Theme.of(context);
    Widget option({
      required IconData icon,
      required String title,
      required String text,
      required VoidCallback onTap,
      bool primary = false,
    }) => Card(
      margin: EdgeInsets.zero,
      color: primary ? theme.colorScheme.primaryContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(text),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
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
                  'How do you want to use Nexus?',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.nexus.muted),
                ),
                const SizedBox(height: 28),
                option(
                  icon: Icons.auto_awesome,
                  title: 'Chat with an AI provider',
                  text:
                      'Sign in to OpenRouter, or use a Claude or OpenAI key. '
                      'No server needed.',
                  primary: true,
                  onTap: () =>
                      ref.read(standaloneModeProvider.notifier).set(true),
                ),
                const SizedBox(height: 12),
                option(
                  icon: Icons.dns_outlined,
                  title: 'Connect an Open WebUI server',
                  text:
                      'Your own server, with its models, memory, tools, files '
                      'and chats on every device.',
                  onTap: () => setState(() => _server = true),
                ),
                const SizedBox(height: 16),
                Text(
                  'You can add the other one later.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.nexus.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
