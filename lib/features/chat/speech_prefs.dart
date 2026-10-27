/// Settings > Audio values, read from the person's settings.
library;

/// The speaking speed saved in Settings > Audio, 1 when unset.
double speechRate(Map<String, dynamic>? settings) {
  final tts = ((settings?['ui'] as Map?)?['audio'] as Map?)?['tts'];
  final rate = tts is Map ? tts['playbackRate'] : null;
  return rate is num && rate > 0 ? rate.toDouble() : 1;
}

/// The language set for speech to text, if any.
String? speechLanguage(Map<String, dynamic>? settings) {
  final stt = ((settings?['ui'] as Map?)?['audio'] as Map?)?['stt'];
  final lang = stt is Map ? stt['language'] : null;
  return lang is String && lang.trim().isNotEmpty ? lang.trim() : null;
}

/// Whether dictated words are sent straight away instead of put in the box.
bool speechAutoSend(Map<String, dynamic>? settings) =>
    (settings?['ui'] as Map?)?['speechAutoSend'] == true;
