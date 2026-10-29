import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/phone_voice.dart';
import 'package:nexus_assistant/features/auth/login_screen.dart';
import 'package:nexus_assistant/features/server/community_share.dart';
import 'package:nexus_assistant/features/settings/keyboard_shortcuts.dart';
import 'package:nexus_assistant/features/workspace/access_editor.dart';

void main() {
  group('keyboard shortcuts', () {
    test('writes key presses as the web does', () {
      expect(
        chordOf(LogicalKeyboardKey.keyO, ctrl: true, shift: true),
        'Cmd+Shift+O',
      );
      expect(chordOf(LogicalKeyboardKey.escape), 'Escape');
      expect(
        chordOf(LogicalKeyboardKey.enter, ctrl: true, shift: true),
        'Cmd+Shift+Enter',
      );
      expect(chordOf(LogicalKeyboardKey.period, ctrl: true), 'Cmd+.');
      expect(chordOf(LogicalKeyboardKey.shiftLeft, shift: true), '');
      expect(showChord('Cmd+Shift+O'), 'Ctrl+Shift+O');
      expect(showChord('Escape'), 'Esc');
    });

    test('finds the shortcut for a key, with saved keys over defaults', () {
      expect(shortcutFor('Cmd+Shift+O', null), 'newChat');
      expect(shortcutFor('Cmd+K', null), 'search');
      final ui = {
        'keybindings': {'newChat': 'Cmd+N'},
      };
      expect(shortcutFor('Cmd+N', ui), 'newChat');
      expect(shortcutFor('Cmd+Shift+O', ui), isNull);
      expect(shortcutFor('Cmd+K', {'keyboardShortcuts': false}), isNull);
      expect(keybindingsOf(ui).length, defaultKeybindings.length);
    });
  });

  test('a server with no accounts shows the first-run welcome', () {
    expect(serverIsFresh('{"onboarding": true}'), isTrue);
    expect(serverIsFresh('{"name": "Open WebUI"}'), isFalse);
    expect(serverIsFresh('not json'), isFalse);
    expect(serverIsFresh(null), isFalse);
  });

  test('phone voices: online ones only when allowed', () {
    const all = [
      PhoneVoiceInfo('en-us-x-local', 'en-US'),
      PhoneVoiceInfo('en-us-x-network', 'en-US', network: true),
    ];
    expect(voicesToOffer(all, nonLocal: false).map((v) => v.name), [
      'en-us-x-local',
    ]);
    expect(voicesToOffer(all, nonLocal: true).length, 2);
    expect(
      phoneSpeechOn({
        'audio': {
          'tts': {'engine': ''},
        },
      }),
      isTrue,
    );
    expect(
      phoneSpeechOn({
        'audio': {
          'tts': {'engine': 'openai'},
        },
      }),
      isFalse,
    );
    expect(phoneSpeechOn(null), isFalse);
  });

  test('community: where each kind is shared, and Support links', () {
    expect(communityPath('model'), '/post?type=model');
    expect(communityPath('prompt'), '/prompts/create');
    expect(communityPath('tool'), '/tools/create');
    expect(communityPath('skill'), '/post?type=skill');
    expect(communityPath('knowledge'), isNull);
    expect(
      fundingUrl({
        'meta': {
          'manifest': {'funding_url': ' https://github.com/sponsors/x '},
        },
      }),
      'https://github.com/sponsors/x',
    );
    expect(fundingUrl({'meta': {}}), isNull);
  });
}
