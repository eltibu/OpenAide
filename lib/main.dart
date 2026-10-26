import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/session.dart';
import 'features/auth/login_screen.dart';
import 'features/chat/chat_screen.dart';

void main() {
  runApp(const ProviderScope(child: NexusApp()));
}

class NexusApp extends ConsumerWidget {
  const NexusApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const seed = Color(0xFF6750A4);
    final session = ref.watch(sessionProvider);
    return MaterialApp(
      title: 'Nexus Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: seed,
          brightness: Brightness.dark,
          useMaterial3: true),
      home: switch (session) {
        AsyncData(value: != null) => const ChatScreen(),
        AsyncLoading() when !session.hasValue => const Scaffold(
            body: Center(child: CircularProgressIndicator())),
        _ => const LoginScreen(),
      },
    );
  }
}
