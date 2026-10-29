/// Phone notifications for finished replies (Settings > Notifications):
/// shown only while the app is in the background; a tap opens the chat.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'read_aloud.dart' show speakable;

const _channel = MethodChannel('nexus/notify');

/// Whether the phone lets the app post notifications.
Future<bool> notificationsAllowed() async {
  try {
    return await _channel.invokeMethod<bool>('allowed') ?? false;
  } on MissingPluginException {
    return false;
  }
}

/// Asks the phone for permission to post notifications (Android 13+).
Future<bool> askForNotifications() async {
  try {
    return await _channel.invokeMethod<bool>('ask') ?? false;
  } on MissingPluginException {
    return false;
  }
}

/// Opens Android's notification settings for Nexus.
Future<void> openNotificationSettings() async {
  try {
    await _channel.invokeMethod('openSettings');
  } on MissingPluginException {
    // Not on a phone.
  }
}

/// Asks for permission, or, when Android won't ask again, opens its
/// settings for Nexus. True when notifications are allowed now.
Future<bool> allowNotifications() async {
  if (await askForNotifications() && await notificationsAllowed()) {
    return true;
  }
  await openNotificationSettings();
  return false;
}

/// True when nobody is looking at the app.
bool get appInBackground {
  final s = WidgetsBinding.instance.lifecycleState;
  return s != null && s != AppLifecycleState.resumed;
}

/// A reply's first words, plain, for the notification.
String notificationText(String reply) {
  final t = speakable(reply).replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 300 ? '${t.substring(0, 300)}…' : t;
}

Future<void> notifyReply({
  required String title,
  required String reply,
  required String chatId,
  bool sound = true,
}) async {
  try {
    await _channel.invokeMethod('notify', {
      'title': title,
      'body': notificationText(reply),
      'chatId': chatId,
      'sound': sound,
    });
  } on MissingPluginException {
    // Not on a phone.
  }
}

/// Calls [open] with the chat a reply notification was tapped for, now
/// (when the app was started by the tap) and whenever one is tapped later.
Future<void> listenForReplyTaps(void Function(String chatId) open) async {
  try {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' &&
          call.arguments is String &&
          (call.arguments as String).isNotEmpty) {
        open(call.arguments as String);
      }
    });
    final first = await _channel.invokeMethod<String>('initialChat');
    if (first != null && first.isNotEmpty) open(first);
  } on MissingPluginException {
    // Not on a phone.
  }
}

/// Whether the phone checks for new replies and channel messages while the
/// app is closed (Settings > Notifications).
Future<bool> backgroundChecksOn() async {
  try {
    return await _channel.invokeMethod<bool>('backgroundOn') ?? false;
  } on MissingPluginException {
    return false;
  }
}

/// Turns the closed-app checks on or off; on, it also hands over the
/// current sign-in, so call it again after signing in anew.
Future<void> setBackgroundChecks(
  bool on, {
  String? baseUrl,
  String? token,
  String? cookie,
}) async {
  try {
    await _channel.invokeMethod('background', {
      'enabled': on,
      'baseUrl': baseUrl,
      'token': token,
      'cookie': cookie,
    });
  } on MissingPluginException {
    // Not on a phone.
  }
}
