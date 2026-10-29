/// The phone's own voices (Android text to speech): used when the server's
/// Text-to-Speech engine is the browser's, where the web speaks with the
/// browser's voices. See PhoneVoice.kt.
library;

import 'package:flutter/services.dart';

const _channel = MethodChannel('nexus/phone_voice');

class PhoneVoiceInfo {
  const PhoneVoiceInfo(this.name, this.locale, {this.network = false});
  final String name;
  final String locale;

  /// Needs the internet (Google's online voices), as the web's non-local
  /// browser voices.
  final bool network;
}

/// Whether the server leaves text to speech to the device (engine "").
bool phoneSpeechOn(Map? config) {
  final tts = (config?['audio'] as Map?)?['tts'] as Map?;
  return tts != null && '${tts['engine'] ?? ''}'.isEmpty;
}

/// The voices, with the online ones only when [nonLocal], as the web's
/// Allow non-local voices.
List<PhoneVoiceInfo> voicesToOffer(
  List<PhoneVoiceInfo> all, {
  required bool nonLocal,
}) => [
  for (final v in all)
    if (nonLocal || !v.network) v,
];

Future<List<PhoneVoiceInfo>> phoneVoices() async {
  final list =
      await _channel.invokeListMethod<Map>('voices') ?? const <Map>[];
  return [
    for (final v in list)
      PhoneVoiceInfo(
        '${v['name']}',
        '${v['locale']}',
        network: v['network'] == true,
      ),
  ];
}

/// Says [text]; returns when it has been said (or stopped).
Future<void> phoneSpeak(String text, {String? voice, double rate = 1}) =>
    _channel.invokeMethod('speak', {
      'text': text,
      'voice': ?voice,
      'rate': rate,
    });

Future<void> phoneStopSpeaking() async {
  try {
    await _channel.invokeMethod('stop');
  } on MissingPluginException {
    // Not on a phone.
  }
}
