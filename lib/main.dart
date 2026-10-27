import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/session.dart';
import 'core/theme.dart';
import 'core/widgets/nexus_logo.dart';
import 'features/auth/login_screen.dart';
import 'features/chat/chat_controller.dart';
import 'features/chat/chat_screen.dart';

void main() {
  runApp(const ProviderScope(child: NexusApp()));
}

class NexusApp extends ConsumerWidget {
  const NexusApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    return MaterialApp(
      title: 'Nexus Assistant',
      debugShowCheckedModeBanner: false,
      theme: nexusTheme(Brightness.light),
      darkTheme: nexusTheme(Brightness.dark),
      // Settings > Theme, kept on the server with the rest.
      themeMode: switch ((ref.watch(userSettingsProvider).value?['ui']
          as Map?)?['nexusTheme']) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      home: switch (session) {
        AsyncData(value: != null) => const ChatScreen(),
        // Spinner only while restoring a saved session; during sign-in the
        // login screen stays up so what was typed isn't lost.
        AsyncLoading() when !ref.read(sessionProvider.notifier).booted =>
          const Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NexusLogo(size: 112),
                  SizedBox(height: 32),
                  CircularProgressIndicator(),
                ],
              ),
            ),
          ),
        _ => const LoginScreen(),
      },
    );
  }
}
