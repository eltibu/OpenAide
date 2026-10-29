/// Settings > Phone and assistant: Nexus as the phone's assistant, what that
/// opens, the quick settings tile, Share and the app lock.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import '../settings/settings_screen.dart';
import 'app_lock.dart';
import 'phone_actions.dart';
import 'phone_launch.dart';
import 'wake_phrase.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/store.dart';

class PhoneSettings extends ConsumerStatefulWidget {
  const PhoneSettings({super.key});

  @override
  ConsumerState<PhoneSettings> createState() => _PhoneSettingsState();
}

class _PhoneSettingsState extends ConsumerState<PhoneSettings>
    with WidgetsBindingObserver {
  bool? _assistant;
  bool _tile = false;
  bool _canLock = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from the phone's settings: see what changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final assistant = await isPhoneAssistant();
    final tile = await canAddTile();
    final lock = await phoneCanLock();
    if (mounted) {
      setState(() {
        _assistant = assistant;
        _tile = tile;
        _canLock = lock;
      });
    }
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr(text))));

  Future<void> _set(Map<String, dynamic> fields) async {
    if (fields.containsKey(assistantOpensKey)) {
      await setAssistPanel(fields[assistantOpensKey] == 'panel');
    }
    try {
      await ref.read(settingsApiProvider).patchUi(fields);
    } catch (e) {
      if (mounted) _say('$e');
    }
    ref.invalidate(uiSettingsProvider);
    ref.invalidate(userSettingsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    // Section names in the accent colour, as on every settings page.
    final heading = Theme.of(context).textTheme.titleSmall
        ?.copyWith(color: Theme.of(context).colorScheme.primary);
    final ui = ref.watch(uiSettingsProvider).value;
    final opens = assistantOpens(ui);
    final lock = ref.watch(appLockProvider).value;
    Widget title(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: heading),
    );
    Widget pick(
      bool on,
      String label,
      VoidCallback onTap, {
      bool enabled = true,
    }) => ListTile(
      enabled: enabled,
      title: Text(label),
      trailing: on ? const Icon(Icons.check, color: NexusColors.accent) : null,
      onTap: onTap,
    );
    return Scaffold(
      appBar: AppBar(title: const T('Phone and assistant')),
      body: ListView(
        children: [
          title('Assistant'),
          ListTile(
            leading: Icon(
              _assistant == true
                  ? Icons.check_circle
                  : Icons.assistant_outlined,
              color: _assistant == true ? NexusColors.accent : null,
            ),
            title: Text(
              _assistant == true
                  ? "OpenAide is your phone's assistant"
                  : "Make OpenAide your phone's assistant",
            ),
            subtitle: Text(
              _assistant == true
                  ? 'Long-press the power or home button to open it.'
                  : 'In the settings that open, choose Digital assistant app > '
                        'OpenAide. Then long-press the power or home '
                        'button.',
              style: TextStyle(color: muted),
            ),
            trailing: const Icon(Icons.open_in_new),
            onTap: openAssistantSettings,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: T(
              'When it opens as the assistant',
              style: TextStyle(color: muted),
            ),
          ),
          pick(opens == 'call', tr('Start a voice call'), () {
            _set({assistantOpensKey: 'call'});
          }),
          pick(opens == 'dictate', tr('Dictate a message'), () {
            _set({assistantOpensKey: 'dictate'});
          }),
          pick(opens == 'new', tr('Open a new chat'), () {
            _set({assistantOpensKey: 'chat'});
          }),
          pick(
            opens == 'panel',
            tr('Ask in a panel over the app you\'re in'),
            () {
              _set({assistantOpensKey: 'panel'});
            },
          ),
          // The Play build has no microphone service, so no wake phrase.
          if (!playBuild) const WakePhraseTile(),
          title('Shortcuts'),
          ListTile(
            leading: const Icon(Icons.dashboard_customize_outlined),
            title: const T('Quick settings tile'),
            subtitle: Text(
              _tile
                  ? 'Starts a voice call from the pull-down menu.'
                  : 'Edit your quick settings and drag the OpenAide tile in. '
                        'It starts a voice call.',
              style: TextStyle(color: muted),
            ),
            trailing: _tile
                ? TextButton(
                    onPressed: () async {
                      if (await addTile()) {
                        _say('OpenAide is in quick settings');
                      }
                    },
                    child: const T('Add'),
                  )
                : null,
          ),
          ListTile(
            leading: const Icon(Icons.touch_app_outlined),
            title: const T('Icon shortcuts'),
            subtitle: T(
              'Long-press the OpenAide icon for Voice call, Dictate and New '
              'chat. Drag one to your home screen to keep it there.',
              style: TextStyle(color: muted),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.widgets_outlined),
            title: const T('Home-screen widget'),
            subtitle: T(
              'Long-press your home screen, choose Widgets, then OpenAide: Ask '
              'OpenAide, Dictate and Voice call in one bar.',
              style: TextStyle(color: muted),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: const T('Share to OpenAide'),
            subtitle: T(
              'In any app, Share > OpenAide starts a chat with the '
              'text, photos or files. Select text anywhere and choose Ask '
              'OpenAide to ask about it.',
              style: TextStyle(color: muted),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.alarm_on_outlined),
            title: const T('Phone actions'),
            subtitle: T(
              'Say or type "set a timer for 10 minutes", "wake me up at 6:30", '
              '"call Mom", "text Sam saying running late", "open Spotify", '
              '"directions to the airport" or "turn on the flashlight" and '
              'the phone does it. Calls and texts open ready for you to press '
              'call or send. Everything else goes to OpenAide.',
              style: TextStyle(color: muted),
            ),
            value: phoneActionsOn(ui),
            onChanged: (on) => _set({phoneActionsKey: on}),
          ),
          title('App lock'),
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const T('Lock OpenAide'),
            subtitle: Text(
              _canLock
                  ? 'Ask for your fingerprint, face or screen lock to open '
                        'the app. Kept on this phone only.'
                  : 'Set a screen lock on your phone first.',
              style: TextStyle(color: muted),
            ),
            value: lock != null,
            onChanged: !_canLock && lock == null
                ? null
                : (on) async {
                    // Turning it on proves you can unlock first.
                    if (on && !await phoneUnlock()) return;
                    await ref
                        .read(appLockProvider.notifier)
                        .set(on ? 60 : null);
                  },
          ),
          if (lock != null)
            for (final MapEntry(key: seconds, value: label)
                in appLockAfter.entries)
              pick(lock == seconds, label, () {
                ref.read(appLockProvider.notifier).set(seconds);
              }),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
