/// Tool servers that need you to sign in (OAuth), as on the web: Reconnect
/// opens the service's sign-in, and Disconnect forgets it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../server/server_page.dart';
import 'chat_controller.dart' show toolsProvider;

/// Where the server starts the sign-in for the tool [id] (such as
/// `server:mcp:abc`), as the web works it out.
String toolSignInPath(String id) {
  final parts = id.split(':');
  final server = parts.last;
  final type = parts.length > 1
      ? (parts.first == 'server' ? parts[1] : parts.first)
      : 'mcp';
  return '/oauth/clients/$type:$server/authorize';
}

/// The session the server keeps for an MCP tool's sign-in.
String toolSessionProvider(String id) => 'mcp:${id.split(':').last}';

/// Signs in to the tool's service on the server's page, then looks again.
Future<void> reconnectTool(
  BuildContext context,
  WidgetRef ref, {
  required String id,
  required String name,
}) async {
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ServerPage(
        title: 'Sign in: $name',
        path: toolSignInPath(id),
        signIn: true,
      ),
    ),
  );
  ref.invalidate(toolsProvider);
}

/// Forgets the sign-in; the tool asks again next time.
Future<void> disconnectTool(
  BuildContext context,
  WidgetRef ref, {
  required String id,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref
        .read(clientProvider)
        .send(
          'DELETE',
          '/api/v1/auths/oauth/sessions/'
              '${Uri.encodeComponent(toolSessionProvider(id))}',
        );
    messenger.showSnackBar(
      const SnackBar(content: Text('OAuth session disconnected')),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text("Couldn't disconnect: $e")));
  }
  ref.invalidate(toolsProvider);
}
