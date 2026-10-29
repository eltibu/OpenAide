/// Keyboard shortcuts for a Bluetooth or USB keyboard, as the web's
/// Settings > Keyboard: the same actions, the same default keys, saved to
/// your account (`keybindings`, `keyboardShortcuts`) so both share them.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart' show userSettingsProvider;
import 'settings_screen.dart' show settingsApiProvider, uiSettingsProvider;

/// Each shortcut: its id (as the web's), name and group.
const shortcutList = <(String, String, String)>[
  ('newChat', 'New Chat', 'Chat'),
  ('newTemporaryChat', 'New Temporary Chat', 'Chat'),
  ('deleteChat', 'Delete Chat', 'Chat'),
  ('openModelSelector', 'Open Model Selector', 'Chat'),
  ('toggleDictation', 'Toggle Dictation', 'Chat'),
  ('navigateChatUp', 'Previous Chat', 'Chat'),
  ('navigateChatDown', 'Next Chat', 'Chat'),
  ('search', 'Search', 'Global'),
  ('openSettings', 'Open Settings', 'Global'),
  ('showShortcuts', 'Show Shortcuts', 'Global'),
  ('toggleSidebar', 'Toggle Sidebar', 'Global'),
  ('toggleControls', 'Toggle Controls', 'Global'),
  ('closeModal', 'Close Modal', 'Global'),
  ('focusInput', 'Focus Chat Input', 'Input'),
  ('clearInputSelections', 'Clear Input Selections', 'Input'),
  ('generateMessagePair', 'Generate Message Pair', 'Message'),
  ('regenerateResponse', 'Regenerate Response', 'Message'),
  ('allowToolCall', 'Allow Tool Call', 'Message'),
  ('denyToolCall', 'Deny Tool Call', 'Message'),
  ('copyLastCodeBlock', 'Copy Last Code Block', 'Message'),
  ('copyLastResponse', 'Copy Last Response', 'Message'),
];

/// The web's defaults. "Cmd" is Ctrl on a phone, as on Windows and Linux.
const defaultKeybindings = <String, String>{
  'newChat': 'Cmd+Shift+O',
  'newTemporaryChat': "Cmd+Shift+'",
  'deleteChat': 'Cmd+Shift+Backspace',
  'openModelSelector': 'Cmd+Shift+M',
  'toggleDictation': 'Cmd+Shift+L',
  'navigateChatUp': '',
  'navigateChatDown': '',
  'search': 'Cmd+K',
  'openSettings': 'Cmd+.',
  'showShortcuts': 'Cmd+/',
  'toggleSidebar': 'Cmd+Shift+S',
  'toggleControls': '',
  'closeModal': 'Escape',
  'focusInput': 'Shift+Escape',
  'clearInputSelections': 'Escape',
  'generateMessagePair': 'Cmd+Shift+Enter',
  'regenerateResponse': 'Cmd+R',
  'allowToolCall': 'Cmd+Alt+Enter',
  'denyToolCall': 'Cmd+Alt+Backspace',
  'copyLastCodeBlock': 'Cmd+Shift+;',
  'copyLastResponse': 'Cmd+Shift+C',
};

/// Your keys: the saved ones over the defaults.
Map<String, String> keybindingsOf(Map? ui) {
  final saved = ui?['keybindings'];
  return {
    for (final e in defaultKeybindings.entries)
      e.key: saved is Map && saved[e.key] is String
          ? saved[e.key] as String
          : e.value,
  };
}

bool shortcutsOn(Map? ui) => ui?['keyboardShortcuts'] != false;

/// A key press written as the web writes it ("Cmd+Shift+O"), or '' for a
/// modifier alone.
String chordOf(
  LogicalKeyboardKey key, {
  bool ctrl = false,
  bool alt = false,
  bool shift = false,
}) {
  final modifiers = <LogicalKeyboardKey>{
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };
  if (modifiers.contains(key)) return '';
  var name = switch (key) {
    LogicalKeyboardKey.escape => 'Escape',
    LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => 'Enter',
    LogicalKeyboardKey.backspace => 'Backspace',
    LogicalKeyboardKey.space => 'Space',
    LogicalKeyboardKey.tab => 'Tab',
    LogicalKeyboardKey.arrowUp => 'ArrowUp',
    LogicalKeyboardKey.arrowDown => 'ArrowDown',
    LogicalKeyboardKey.arrowLeft => 'ArrowLeft',
    LogicalKeyboardKey.arrowRight => 'ArrowRight',
    _ => key.keyLabel,
  };
  if (name.isEmpty) return '';
  if (name.length == 1) name = name.toUpperCase();
  name = switch (name) {
    '"' => "'",
    ':' => ';',
    '?' => '/',
    '{' => '[',
    '}' => ']',
    _ => name,
  };
  return [if (ctrl) 'Cmd', if (alt) 'Alt', if (shift) 'Shift', name].join('+');
}

/// The chord for a key going down right now.
String chordNow(LogicalKeyboardKey key) {
  final k = HardwareKeyboard.instance;
  return chordOf(
    key,
    ctrl: k.isControlPressed || k.isMetaPressed,
    alt: k.isAltPressed,
    shift: k.isShiftPressed,
  );
}

/// How a chord reads on screen: "Ctrl+Shift+O", "Esc".
String showChord(String chord) => chord
    .split('+')
    .map(
      (p) => switch (p) {
        'Cmd' => 'Ctrl',
        'Escape' => 'Esc',
        _ => p,
      },
    )
    .join('+');

/// Which shortcut [chord] runs, if any (the first, as the web's lookup).
String? shortcutFor(String chord, Map? ui) {
  if (chord.isEmpty || !shortcutsOn(ui)) return null;
  for (final e in keybindingsOf(ui).entries) {
    if (e.value == chord) return e.key;
  }
  return null;
}

/// A shortcut for the chat box ("focusInput", "generateMessagePair",
/// "clearInputSelections"), handed over from the screen. Counts up so the
/// same one twice still arrives.
class ComposerShortcut extends Notifier<(String, int)?> {
  @override
  (String, int)? build() => null;

  void send(String id) => state = (id, (state?.$2 ?? 0) + 1);
}

final composerShortcutProvider =
    NotifierProvider<ComposerShortcut, (String, int)?>(ComposerShortcut.new);

class KeyboardShortcutsScreen extends ConsumerStatefulWidget {
  const KeyboardShortcutsScreen({super.key});

  @override
  ConsumerState<KeyboardShortcutsScreen> createState() =>
      _KeyboardShortcutsState();
}

class _KeyboardShortcutsState extends ConsumerState<KeyboardShortcutsScreen> {
  Future<void> _save(Map<String, dynamic> fields) async {
    try {
      await ref.read(settingsApiProvider).patchUi(fields);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    ref
      ..invalidate(uiSettingsProvider)
      ..invalidate(userSettingsProvider);
  }

  /// Click to rebind: the next key pressed becomes the shortcut; Esc
  /// cancels, Clear leaves it unassigned.
  Future<void> _rebind(String id, String name, Map ui) async {
    final chord = await showDialog<String>(
      context: context,
      builder: (d) => _RecordKey(name: name),
    );
    if (chord == null) return;
    await _save({
      'keybindings': {...keybindingsOf(ui), id: chord},
    });
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(uiSettingsProvider).value ?? const {};
    final muted = context.nexus.muted;
    final keys = keybindingsOf(ui);
    final on = shortcutsOn(ui);
    String? clash(String id) {
      final chord = keys[id] ?? '';
      if (chord.isEmpty || chord == 'Escape') return null;
      for (final (other, name, _) in shortcutList) {
        if (other != id && keys[other] == chord) return name;
      }
      return null;
    }

    return Scaffold(
      appBar: AppBar(
        title: const T('Keyboard shortcuts'),
        actions: [
          TextButton(
            onPressed: () => _save({'keybindings': Map.of(defaultKeybindings)}),
            child: const T('Reset Defaults'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          SwitchListTile(
            title: const T('Enable Keyboard Shortcuts'),
            subtitle: T(
              'For a Bluetooth or USB keyboard. Saved to your account, so '
              'the web uses the same keys.',
              style: TextStyle(color: muted),
            ),
            value: on,
            onChanged: (v) => _save({'keyboardShortcuts': v}),
          ),
          for (final group in ['Chat', 'Global', 'Input', 'Message']) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: T(
                group,
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(color: NexusColors.accent),
              ),
            ),
            for (final (id, name, g) in shortcutList)
              if (g == group)
                ListTile(
                  enabled: on,
                  title: T(name),
                  subtitle: clash(id) == null
                      ? null
                      : Text(
                          tr('Also used by {{NAME}}')
                              .replaceAll('{{NAME}}', tr(clash(id)!)),
                          style: const TextStyle(color: Colors.orange),
                        ),
                  trailing: Tooltip(
                    message: tr('Click to rebind'),
                    child: Chip(
                      label: Text(
                        (keys[id] ?? '').isEmpty
                            ? tr('Unassigned')
                            : showChord(keys[id]!),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          color: (keys[id] ?? '').isEmpty ? muted : null,
                        ),
                      ),
                    ),
                  ),
                  onTap: () => _rebind(id, name, ui),
                ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: T(
              'Also: Tab accepts a suggestion, # attaches a file and / adds a '
              'saved prompt.',
              style: TextStyle(color: muted, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordKey extends StatefulWidget {
  const _RecordKey({required this.name});
  final String name;

  @override
  State<_RecordKey> createState() => _RecordKeyState();
}

class _RecordKeyState extends State<_RecordKey> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr(widget.name)),
    content: Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.handled;
        if (event.logicalKey == LogicalKeyboardKey.escape &&
            !HardwareKeyboard.instance.isShiftPressed) {
          Navigator.pop(context);
          return KeyEventResult.handled;
        }
        final chord = chordNow(event.logicalKey);
        if (chord.isNotEmpty) Navigator.pop(context, chord);
        return KeyEventResult.handled;
      },
      child: const T('Press the new keys on your keyboard. Esc cancels.'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, ''),
        child: const T('Unassigned'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const T('Cancel'),
      ),
    ],
  );
}
