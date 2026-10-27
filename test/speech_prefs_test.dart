import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/speech_prefs.dart';

void main() {
  test('Settings > Audio values', () {
    expect(speechRate(null), 1);
    expect(speechLanguage(null), isNull);
    expect(speechAutoSend(null), false);
    final s = {
      'ui': {
        'speechAutoSend': true,
        'audio': {
          'stt': {'language': ' es '},
          'tts': {'playbackRate': 1.5},
        },
      },
    };
    expect(speechRate(s), 1.5);
    expect(speechLanguage(s), 'es');
    expect(speechAutoSend(s), true);
  });
}
