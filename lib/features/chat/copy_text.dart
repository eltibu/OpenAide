/// Copying a message, as the web's Copy: with Settings > Interface > Copy
/// formatted text on, the clipboard also holds the reply as formatted text
/// (HTML), so headings, lists and links survive a paste into another app.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown/markdown.dart' as md;

import 'chat_controller.dart' show userSettingsProvider;

const _channel = MethodChannel('nexus/clipboard');

/// The HTML a formatted copy of [markdown] holds.
String copyHtml(String markdown) =>
    md.markdownToHtml(markdown, extensionSet: md.ExtensionSet.gitHubWeb);

bool copyFormattedOn(WidgetRef ref) =>
    (ref.read(userSettingsProvider).value?['ui'] as Map?)?['copyFormatted'] ==
    true;

/// Copies [text], formatted when the setting is on.
Future<void> copyMessage(WidgetRef ref, String text) async {
  if (copyFormattedOn(ref) &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android) {
    try {
      await _channel.invokeMethod('html', {
        'text': text,
        'html': copyHtml(text),
      });
      return;
    } on MissingPluginException {
      // Older Android code: plain text below.
    } on PlatformException {
      // As above.
    }
  }
  await Clipboard.setData(ClipboardData(text: text));
}
