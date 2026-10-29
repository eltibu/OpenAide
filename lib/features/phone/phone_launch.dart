/// Ways the phone opens Nexus besides its icon: as the phone's assistant,
/// Share from another app, "Ask Nexus" on selected text, the icon's
/// shortcuts and the quick settings tile. Android hands each over on the
/// "nexus/launch" channel (see PhoneLaunch.kt).
library;

import 'dart:io';

import 'package:flutter/services.dart';

const phoneChannel = MethodChannel('nexus/launch');

/// One way in: [kind] is assist, share, call, dictate or new.
class PhoneLaunch {
  const PhoneLaunch(this.kind, {this.text = '', this.files = const []});
  final String kind;
  final String text;

  /// Shared files, copied into the app's cache.
  final List<String> files;

  static PhoneLaunch? fromMap(Object? m) {
    if (m is! Map || m['kind'] is! String) return null;
    return PhoneLaunch(
      m['kind'] as String,
      text: '${m['text'] ?? ''}',
      files: [
        for (final f in m['files'] as List? ?? const [])
          if (f is String) f,
      ],
    );
  }
}

/// What opening Nexus as the phone's assistant does, kept with your other
/// settings on the server: call, dictate or chat.
const assistantOpensKey = 'nexusAssistantOpens';

String assistantOpens(Map? ui) => switch (ui?[assistantOpensKey]) {
  'dictate' => 'dictate',
  'chat' => 'new',
  'panel' => 'panel',
  _ => 'call',
};

/// Tells Android whether the assistant opens as a panel over other apps
/// (see AssistEntry.kt); it has to know before the app starts.
Future<void> setAssistPanel(bool on) async {
  try {
    await phoneChannel.invokeMethod('overlay', {'on': on});
  } on MissingPluginException {
    // Not on a phone.
  }
}

/// From the panel: carries on in the full app, at [chatId] if there is one.
Future<void> openAppFromPanel(String? chatId) async {
  try {
    await phoneChannel.invokeMethod('openApp', {'chatId': chatId});
  } on MissingPluginException {
    // Not on a phone.
  }
}

/// Closes the panel, back to the app it was over.
Future<void> closeAssistPanel() async {
  try {
    await phoneChannel.invokeMethod('close');
  } on MissingPluginException {
    // Not on a phone.
  }
}

/// What [launch] comes down to: the assistant button takes your setting.
String launchAction(PhoneLaunch launch, Map? ui) =>
    launch.kind == 'assist' ? assistantOpens(ui) : launch.kind;

/// Calls [on] for the launch that started the app, and for each later one.
Future<void> listenForLaunches(void Function(PhoneLaunch) on) async {
  try {
    phoneChannel.setMethodCallHandler((call) async {
      if (call.method != 'launch') return;
      final launch = PhoneLaunch.fromMap(call.arguments);
      if (launch != null) on(launch);
    });
    final first = PhoneLaunch.fromMap(
      await phoneChannel.invokeMethod<Object?>('initial'),
    );
    if (first != null) on(first);
  } on MissingPluginException {
    // Not on a phone.
  }
}

/// A shared file's bytes and name, or null when it can't be read.
Future<(List<int>, String)?> readShared(String path) async {
  try {
    final f = File(path);
    return (await f.readAsBytes(), f.uri.pathSegments.last);
  } on FileSystemException {
    return null;
  }
}

/// Whether Nexus is the phone's assistant (null when the phone can't say).
Future<bool?> isPhoneAssistant() async {
  try {
    return await phoneChannel.invokeMethod<bool>('isAssistant');
  } on MissingPluginException {
    return null;
  }
}

Future<void> openAssistantSettings() async {
  try {
    await phoneChannel.invokeMethod('openAssistantSettings');
  } on MissingPluginException {
    // Not on a phone.
  }
}

Future<bool> canAddTile() async {
  try {
    return await phoneChannel.invokeMethod<bool>('canAddTile') ?? false;
  } on MissingPluginException {
    return false;
  }
}

/// Asks the phone to add the quick settings tile; true once it's there.
Future<bool> addTile() async {
  try {
    final code = await phoneChannel.invokeMethod<String>('addTile');
    // 1: already added, 2: added.
    return code == '1' || code == '2';
  } on MissingPluginException {
    return false;
  }
}
