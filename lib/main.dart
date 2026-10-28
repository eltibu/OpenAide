import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'core/api/openwebui_client.dart';
import 'core/offline/offline_cache.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/session.dart';
import 'core/theme.dart';
import 'core/widgets/nexus_logo.dart';
import 'features/auth/welcome_screen.dart';
import 'features/auth/sign_in_steps.dart';
import 'features/chat/chat_controller.dart';
import 'features/chat/chat_screen.dart';
import 'features/chat/in_app_toasts.dart';
import 'features/chat/server_asks.dart';
import 'features/phone/app_lock.dart';
import 'features/standalone/local_chats.dart';
import 'features/standalone/standalone_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Saved copies of your chats, for opening them with no connection.
  try {
    final support = await getApplicationSupportDirectory();
    OpenWebUiClient.offline = FileOfflineStore(
      Directory('${support.path}/offline'),
    );
  } catch (_) {
    // No saved copies; everything still loads from the server.
  }
  runApp(const ProviderScope(child: NexusApp()));
}

class NexusApp extends ConsumerWidget {
  const NexusApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    return MaterialApp(
      title: 'OpenAide',
      debugShowCheckedModeBanner: false,
      // Settings > Phone and assistant > App lock.
      builder: (context, child) =>
          AppLockGate(child: OfflineStrip(child: child!)),
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
        // Signed in, but an admin hasn't approved the account yet.
        AsyncData(value: final s?) when s.user?['role'] == 'pending' =>
          PendingScreen(
            signedIn: true,
            onCheck: () => ref.read(sessionProvider.notifier).recheck(),
          ),
        AsyncData(value: != null) => const InAppToasts(
          child: ServerAsks(child: ChatScreen()),
        ),
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
        _ when ref.watch(standaloneModeProvider).isLoading => const Scaffold(),
        // Signed out: chats with AI providers only, when chosen.
        _ when ref.watch(standaloneModeProvider).value == true =>
          const StandaloneScreen(),
        _ => const WelcomeScreen(),
      },
    );
  }
}
