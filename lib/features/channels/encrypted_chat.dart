/// Encrypted chats in a channel, as the web's: end-to-end encrypted, kept
/// only while the people in it are there, never saved on the server. The
/// encryption runs in the web's own code, so the chat opens in the server's
/// page; the app shows when one is going on and opens it.
library;

import 'package:flutter/material.dart';

import '../server/server_page.dart';
import 'channels_api.dart';

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

/// Opens the channel on the server's page, where Encrypted Chat (or Join)
/// starts it.
void openEncryptedChat(BuildContext context, Channel c, {required bool join}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 6),
      content: Text(
        join
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
