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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _set(Map<String, dynamic> fields) async {
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
    final heading = Theme.of(context).textTheme.titleSmall;
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
      appBar: AppBar(title: const Text('Phone and assistant')),
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
                  ? "Nexus is your phone's assistant"
                  : "Make Nexus your phone's assistant",
            ),
            subtitle: Text(
              _assistant == true
                  ? 'Long-press the power or home button to open it.'
                  : 'In the settings that open, choose Digital assistant app > '
                        'Nexus Assistant. Then long-press the power or home '
                        'button.',
              style: TextStyle(color: muted),
            ),
            trailing: const Icon(Icons.open_in_new),
            onTap: openAssistantSettings,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'When it opens as the assistant',
              style: TextStyle(color: muted),
            ),
          ),
          pick(opens == 'call', 'Start a voice call', () {
            _set({assistantOpensKey: 'call'});
          }),
          pick(opens == 'dictate', 'Dictate a message', () {
            _set({assistantOpensKey: 'dictate'});
          }),
          pick(opens == 'new', 'Open a new chat', () {
            _set({assistantOpensKey: 'chat'});
          }),
          title('Shortcuts'),
          ListTile(
            leading: const Icon(Icons.dashboard_customize_outlined),
            title: const Text('Quick settings tile'),
            subtitle: Text(
              _tile
                  ? 'Starts a voice call from the pull-down menu.'
                  : 'Edit your quick settings and drag the Nexus tile in. '
                        'It starts a voice call.',
              style: TextStyle(color: muted),
            ),
            trailing: _tile
                ? TextButton(
                    onPressed: () async {
                      if (await addTile()) _say('Nexus is in quick settings');
                    },
                    child: const Text('Add'),
                  )
                : null,
          ),
          ListTile(
            leading: const Icon(Icons.touch_app_outlined),
            title: const Text('Icon shortcuts'),
            subtitle: Text(
              'Long-press the Nexus icon for Voice call, Dictate and New '
              'chat. Drag one to your home screen to keep it there.',
              style: TextStyle(color: muted),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.widgets_outlined),
            title: const Text('Home-screen widget'),
            subtitle: Text(
              'Long-press your home screen, choose Widgets, then Nexus: Ask '
              'Nexus, Dictate and Voice call in one bar.',
              style: TextStyle(color: muted),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: const Text('Share to Nexus'),
            subtitle: Text(
              'In any app, Share > Nexus Assistant starts a chat with the '
              'text, photos or files. Select text anywhere and choose Ask '
              'Nexus to ask about it.',
              style: TextStyle(color: muted),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.alarm_on_outlined),
            title: const Text('Phone actions'),
            subtitle: Text(
              'Say or type "set a timer for 10 minutes", "wake me up at 6:30", '
              '"call Mom", "text Sam saying running late", "open Spotify", '
              '"directions to the airport" or "turn on the flashlight" and '
              'the phone does it. Calls and texts open ready for you to press '
              'call or send. Everything else goes to Nexus.',
              style: TextStyle(color: muted),
            ),
            value: phoneActionsOn(ui),
            onChanged: (on) => _set({phoneActionsKey: on}),
          ),
          title('App lock'),
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const Text('Lock Nexus'),
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
