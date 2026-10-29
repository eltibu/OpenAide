/// Encrypted chats in a channel, as the web's: end-to-end encrypted, kept
/// only while the people in it are there, never saved on the server. The
/// app runs the web's own encryption code (see mls.dart).
library;

import 'package:flutter/material.dart';

import '../server/server_page.dart';
import 'channels_api.dart';
import 'encrypted_chat_screen.dart';
import 'mls.dart';

/// Whether [me] may use encrypted chats on a server with [features], as
/// the web decides.
bool canUseEncryption(Map? me, Map? features) {
  if (features?['enable_channels'] != true ||
      features?['enable_encrypted_channels'] != true) {
    return false;
  }
  if (me?['role'] == 'admin') return true;
  final allowed = (me?['permissions'] as Map?)?['features'] as Map?;
  return me?['role'] == 'user' &&
      allowed?['channels'] == true &&
      allowed?['encrypted_channels'] == true;
}

/// Encrypted chats work in direct messages and private groups only.
bool encryptionFits(Channel c) => c.isDm || (c.type == 'group' && c.isPrivate);

/// Starts the encrypted chat in [c], or joins [session]: in the app when it
/// has the encryption built in, else on the server's page.
void openEncryptedChat(
  BuildContext context,
  Channel c, {
  required String title,
  String? session,
}) {
  if (mlsAvailable) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            EncryptedChatScreen(channel: c.id, title: title, session: session),
      ),
    );
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 6),
      content: Text(
        session != null
            ? 'Tap Join under the channel name to join the encrypted chat.'
            : 'Tap the menu at the top, then Encrypted Chat.',
      ),
    ),
  );
  Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ServerPage(
        title: 'Encrypted chat',
        path: '/channels/${Uri.encodeComponent(c.id)}',
      ),
    ),
  );
}
