import '../agent/agent_settings_screen.dart';
import '../providers/ai_providers_screen.dart';
import '../providers/local_models_screen.dart';
import '../phone/phone_settings.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../accounts/accounts_screen.dart';
import '../chat/advanced_params.dart';
import '../chat/chat_controller.dart';
import '../update/update_screen.dart';
import 'audio_settings.dart';
import 'account_extras.dart';
import 'keyboard_shortcuts.dart';
import 'data_controls.dart';
import 'direct_connections.dart';
import 'tool_servers.dart';
import 'interface_settings.dart';
import 'notification_settings.dart';
import 'settings_api.dart';
import 'about_screen.dart';
import 'terminal_connections.dart';
import 'two_step_settings.dart';
import 'usage_screen.dart';
import '../../core/i18n/app_strings.dart';
import 'language_settings.dart';

final settingsApiProvider = Provider<SettingsApi>(
  (ref) => SettingsApi(ref.watch(clientProvider)),
);

/// The signed-in person as the server has them now (name, picture, bio).
final meProvider = FutureProvider<Map<String, dynamic>>(
  (ref) => ref.watch(settingsApiProvider).me(),
);

/// The person's own `ui` settings, raw.
final uiSettingsProvider = FutureProvider<Map<String, dynamic>>(
  (ref) => ref.watch(settingsApiProvider).ui(),
);

final memoriesProvider = FutureProvider<List<Memory>>(
  (ref) => ref.watch(settingsApiProvider).memories(),
);

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(text))));

Future<bool> _confirm(
  BuildContext context,
  String title,
  String body,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(action),
          ),
        ],
      ),
    ) ==
    true;

/// The person's picture: the server's profile image, signed in.
class Avatar extends ConsumerWidget {
  const Avatar({super.key, required this.user, this.radius = 20});
  final Map<String, dynamic>? user;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    final name = '${user?['name'] ?? ''}'.trim();
    final initials = name.isEmpty
        ? '?'
        : name
              .split(RegExp(r'\s+'))
              .take(2)
              .map((w) => w[0].toUpperCase())
              .join();
    final url = '${user?['profile_image_url'] ?? ''}';
    ImageProvider? image;
    if (url.startsWith('data:image/')) {
      final comma = url.indexOf(',');
      try {
        image = MemoryImage(base64Decode(url.substring(comma + 1)));
      } catch (_) {}
    } else if (url.startsWith('http')) {
      image = NetworkImage(url);
    } else if (url.startsWith('/') && url != '/user.png') {
      image = NetworkImage(
        client.serverUri(url).toString(),
        headers: client.authHeaders,
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      foregroundImage: image,
      onForegroundImageError: image == null ? null : (_, _) {},
      child: Text(initials, style: TextStyle(fontSize: radius * 0.8)),
    );
  }
}

/// Settings, like the web's Settings window: account, chats, memory, and
/// the app's own updates.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider).value;
    final muted = context.nexus.muted;
    void open(Widget page) =>
        Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
    return Scaffold(
      appBar: AppBar(title: const T('Settings')),
      body: ListView(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            leading: Avatar(user: me, radius: 26),
            title: Text('${me?['name'] ?? 'Account'}'),
            subtitle: Text(
              '${me?['email'] ?? ''}',
              style: TextStyle(color: muted),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(const AccountSettings()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const T('General'),
            subtitle: const T('Your system prompt and model settings'),
            onTap: () => open(const GeneralSettings()),
          ),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const T('Theme'),
            subtitle: T(themeName(ref)),
            onTap: () => _pickTheme(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: const T('Chats'),
            subtitle: const T('Titles, tags, suggestions, temporary chats'),
            onTap: () => open(const ChatSettings()),
          ),
          ListTile(
            leading: const Icon(Icons.view_quilt_outlined),
            title: const T('Interface'),
            subtitle: const T('Message box, images, embeds and more'),
            onTap: () => open(const InterfaceSettings()),
          ),
          ListTile(
            leading: const Icon(Icons.keyboard_outlined),
            title: const T('Keyboard'),
            subtitle: const T('Shortcuts for a Bluetooth or USB keyboard'),
            onTap: () => open(const KeyboardShortcutsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.graphic_eq),
            title: const T('Audio'),
            subtitle: const T('Voice, speed, dictation and read aloud'),
            onTap: () => open(const AudioSettings()),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const T('Notifications'),
            subtitle: const T('When a reply is ready, and webhooks'),
            onTap: () => open(const NotificationSettings()),
          ),
          ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const T('Accounts'),
            subtitle: const T(
              'Sign in with Google or Microsoft, and other email',
            ),
            onTap: () => open(const AccountsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: const T('Phone and assistant'),
            subtitle: const T('Default assistant, shortcuts, Share, app lock'),
            onTap: () => open(const PhoneSettings()),
          ),
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const T('AI providers'),
            subtitle: const T('OpenRouter, Claude, OpenAI and GitHub Copilot'),
            onTap: () => open(const AiProvidersScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.download_for_offline_outlined),
            title: const T('Models on this phone'),
            subtitle: const T('Download models that run offline'),
            onTap: () => open(const LocalModelsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.handyman_outlined),
            title: const T('Tools and skills on this phone'),
            subtitle: const T(
              'Web, phone, skills and MCP for models without a server',
            ),
            onTap: () => open(const AgentSettingsScreen()),
          ),
          if ((ref.watch(serverConfigProvider).value?['features']
                  as Map?)?['enable_direct_connections'] ==
              true)
            ListTile(
              leading: const Icon(Icons.cable),
              title: const T('Connections'),
              subtitle: const T('Your own OpenAI-compatible servers'),
              onTap: () => open(const DirectConnectionsScreen()),
            ),
          if (directIntegrationsOn(ref.watch(serverConfigProvider).value))
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: const T('Integrations'),
              subtitle: const T('Your own OpenAPI tool servers'),
              onTap: () => open(const ToolServersScreen()),
            ),
          ListTile(
            leading: const Icon(Icons.terminal),
            title: const T('Terminal connections'),
            subtitle: const T('Your own Open Terminal servers'),
            onTap: () => open(const TerminalConnectionsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const T('Data controls'),
            subtitle: const T('Import, export, shared chats, your files'),
            onTap: () => open(const DataControls()),
          ),
          ListTile(
            leading: const Icon(Icons.insights_outlined),
            title: const T('Usage'),
            subtitle: const T('Tokens, streaks and your top models'),
            onTap: () => open(const UsageScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.psychology_alt_outlined),
            title: const T('Memory'),
            subtitle: const T('What models remember about you'),
            onTap: () => open(const MemoriesScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const T('About'),
            subtitle: const T("Server version and what's new"),
            onTap: () => open(const AboutScreen()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: const T('App updates'),
            onTap: () => open(const UpdateScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const T('Sign out'),
            onTap: () async {
              if (!await _confirm(
                context,
                'Sign out?',
                'You will need to sign in again to use the app.',
                'Sign out',
              )) {
                return;
              }
              if (context.mounted) Navigator.pop(context);
              await ref.read(sessionProvider.notifier).signOut();
            },
          ),
        ],
      ),
    );
  }
}

String themeName(WidgetRef ref) =>
    switch ((ref.watch(userSettingsProvider).value?['ui']
        as Map?)?['nexusTheme']) {
      'light' => 'Light',
      'dark' => 'Dark',
      'oled-dark' => 'OLED Dark',
      _ => 'Same as the phone',
    };

Future<void> _pickTheme(BuildContext context, WidgetRef ref) async {
  final now =
      (ref.read(userSettingsProvider).value?['ui'] as Map?)?['nexusTheme'] ??
      'system';
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (id, label) in const [
            ('system', 'Same as the phone'),
            ('light', 'Light'),
            ('dark', 'Dark'),
            ('oled-dark', 'OLED Dark'),
          ])
            ListTile(
              leading: Icon(
                id == now ? Icons.radio_button_checked : Icons.radio_button_off,
              ),
              title: T(label),
              onTap: () => Navigator.pop(context, id),
            ),
        ],
      ),
    ),
  );
  if (picked == null || picked == now) return;
  try {
    await ref.read(settingsApiProvider).patchUi({
      'nexusTheme': picked == 'system' ? null : picked,
    });
  } catch (e) {
    if (context.mounted) _say(context, '$e');
  }
  ref.invalidate(uiSettingsProvider);
  ref.invalidate(userSettingsProvider);
}

// ---- Account ----

class AccountSettings extends ConsumerStatefulWidget {
  const AccountSettings({super.key});

  @override
  ConsumerState<AccountSettings> createState() => _AccountSettingsState();
}

class _AccountSettingsState extends ConsumerState<AccountSettings> {
  final _name = TextEditingController();
  final _bio = TextEditingController();
  final _gender = TextEditingController();
  String _genderChoice = '';
  String _birth = '';
  String _image = '';
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ref.read(meProvider.future).then((me) {
      if (!mounted) return;
      setState(() {
        _name.text = '${me['name'] ?? ''}';
        _bio.text = '${me['bio'] ?? ''}';
        _image = '${me['profile_image_url'] ?? ''}';
        final g = '${me['gender'] ?? ''}';
        _genderChoice = const ['', 'male', 'female'].contains(g) ? g : 'custom';
        _gender.text = _genderChoice == 'custom' ? g : '';
        _birth = '${me['date_of_birth'] ?? ''}';
        _loaded = true;
      });
    }, onError: (Object e) => setState(() => _loaded = true));
  }

  Future<void> _pickImage() async {
    // Small and square-ish, as the web crops profile pictures.
    final photo = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 256,
      maxHeight: 256,
      imageQuality: 85,
    );
    if (photo == null) return;
    final bytes = await photo.readAsBytes();
    final type = (photo.mimeType ?? 'image/jpeg').contains('png')
        ? 'image/png'
        : 'image/jpeg';
    setState(() => _image = 'data:$type;base64,${base64Encode(bytes)}');
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _say(context, 'Your name can\'t be empty');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(settingsApiProvider)
          .updateProfile(
            name: name,
            imageUrl: _image,
            bio: _bio.text.trim(),
            gender: _genderChoice == 'custom'
                ? _gender.text.trim()
                : _genderChoice,
            dateOfBirth: _birth,
          );
      ref.invalidate(meProvider);
      if (mounted) {
        _say(context, 'Saved');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: const T('Account'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy || !_loaded ? null : _save,
              child: const T('Save'),
            ),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: Stack(
                    children: [
                      Avatar(
                        user: {'name': _name.text, 'profile_image_url': _image},
                        radius: 44,
                      ),
                      Positioned(
                        right: -4,
                        bottom: -4,
                        child: IconButton.filledTonal(
                          tooltip: tr('Change picture'),
                          onPressed: _pickImage,
                          icon: const Icon(Icons.photo_camera_outlined),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_image.startsWith('data:'))
                  Center(
                    child: TextButton(
                      onPressed: () => setState(() => _image = '/user.png'),
                      child: const T('Remove picture'),
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _name,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(labelText: tr('Name')),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _bio,
                  maxLines: null,
                  decoration: InputDecoration(labelText: tr('About you')),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _genderChoice,
                  decoration: InputDecoration(labelText: tr('Gender')),
                  items: const [
                    DropdownMenuItem(value: '', child: T('Prefer not to say')),
                    DropdownMenuItem(value: 'male', child: T('Male')),
                    DropdownMenuItem(value: 'female', child: T('Female')),
                    DropdownMenuItem(value: 'custom', child: T('Custom')),
                  ],
                  onChanged: (v) => setState(() => _genderChoice = v ?? ''),
                ),
                if (_genderChoice == 'custom')
                  TextField(
                    controller: _gender,
                    decoration: InputDecoration(labelText: tr('Your gender')),
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const T('Birth date'),
                  subtitle: Text(_birth.isEmpty ? 'Not set' : _birth),
                  trailing: _birth.isEmpty
                      ? const Icon(Icons.calendar_today_outlined)
                      : IconButton(
                          tooltip: tr('Clear'),
                          onPressed: () => setState(() => _birth = ''),
                          icon: const Icon(Icons.close),
                        ),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      firstDate: DateTime(1900),
                      lastDate: DateTime.now(),
                      initialDate: DateTime.tryParse(_birth) ?? DateTime(1990),
                    );
                    if (picked != null) {
                      setState(
                        () =>
                            _birth = picked.toIso8601String().substring(0, 10),
                      );
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const T('Email'),
                  subtitle: Text('${me?['email'] ?? ''}'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const T('Role'),
                  subtitle: Text('${me?['role'] ?? ''}'),
                ),
                const Divider(),
                const AccountStatus(),
                const ChangePassword(),
                const TwoStepSettings(),
                const Divider(),
                const ApiKeys(),
              ],
            ),
    );
  }
}

// ---- General ----

class GeneralSettings extends ConsumerStatefulWidget {
  const GeneralSettings({super.key});

  @override
  ConsumerState<GeneralSettings> createState() => _GeneralSettingsState();
}

class _GeneralSettingsState extends ConsumerState<GeneralSettings> {
  final _system = TextEditingController();
  Map<String, dynamic> _params = {};
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ref.read(uiSettingsProvider.future).then((ui) {
      if (!mounted) return;
      final params = (ui['params'] as Map?)?.cast<String, dynamic>() ?? {};
      setState(() {
        _system.text = '${ui['system'] ?? ''}';
        _params = {...params};
        _loaded = true;
      });
    }, onError: (Object e) => setState(() => _loaded = true));
  }

  Future<void> _save() async {
    final params = _params;
    final system = _system.text.trim();
    setState(() => _busy = true);
    try {
      await ref.read(settingsApiProvider).patchUi({
        'system': system.isEmpty ? null : system,
        'params': params,
      });
      ref.invalidate(uiSettingsProvider);
      ref.invalidate(userSettingsProvider);
      if (mounted) {
        _say(context, 'Saved');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) _say(context, '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const T('General'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy || !_loaded ? null : _save,
              child: const T('Save'),
            ),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [
                // The web's WebUI Settings: Theme and Language.
                T(
                  'WebUI Settings',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.brightness_6_outlined),
                  title: const T('Theme'),
                  subtitle: T(themeName(ref)),
                  onTap: () => _pickTheme(context, ref),
                ),
                // Settings > General > Language, kept on this phone as on
                // the web.
                ListenableBuilder(
                  listenable: AppStrings.instance,
                  builder: (context, _) => FutureBuilder<String>(
                    future: languageName(AppStrings.instance.choice),
                    builder: (context, name) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.translate),
                      title: const T('Language'),
                      subtitle: Text(name.data ?? ''),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const LanguageSettings(),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _system,
                  minLines: 4,
                  maxLines: null,
                  decoration: InputDecoration(
                    labelText: tr('System prompt'),
                    helperText: tr('Instructions every chat starts with'),
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),
                T('Model settings', style: TextStyle(color: muted)),
                T(
                  'Left on Default, the model\'s own setting is used. A chat\'s '
                  'Controls can change them for that chat.',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: muted),
                ),
                AdvancedParamsEditor(
                  params: _params,
                  onChanged: (k, v) => setState(
                    () => v == null ? _params.remove(k) : _params[k] = v,
                  ),
                ),
              ],
            ),
    );
  }
}

// ---- Chats ----

class ChatSettings extends ConsumerWidget {
  const ChatSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(uiSettingsProvider);
    final muted = context.nexus.muted;
    Future<void> set(Map<String, dynamic> fields) async {
      try {
        await ref.read(settingsApiProvider).patchUi(fields);
      } catch (e) {
        if (context.mounted) _say(context, '$e');
      }
      ref.invalidate(uiSettingsProvider);
      ref.invalidate(userSettingsProvider);
    }

    Future<void> act(
      String title,
      String body,
      String action,
      Future<void> Function() run,
      String done,
    ) async {
      if (!await _confirm(context, title, body, action)) return;
      try {
        await run();
        refreshChatLists(ref.invalidate);
        if (context.mounted) _say(context, done);
      } catch (e) {
        if (context.mounted) _say(context, '$e');
      }
    }

    return Scaffold(
      appBar: AppBar(title: const T('Chats')),
      body: ui.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Couldn\'t load your settings.\n$e'),
        ),
        data: (ui) {
          final title = (ui['title'] as Map?) ?? const {};
          return ListView(
            children: [
              SwitchListTile(
                title: const T('Name new chats'),
                subtitle: const T('Give each chat a title from its start'),
                value: title['auto'] != false,
                onChanged: (on) => set({
                  'title': {...title, 'auto': on},
                }),
              ),
              SwitchListTile(
                title: const T('Tag chats'),
                subtitle: const T('Add topic tags to chats'),
                value: ui['autoTags'] != false,
                onChanged: (on) => set({'autoTags': on}),
              ),
              SwitchListTile(
                title: const T('Always search the web'),
                subtitle: const T(
                  'Start every chat with web search on, where it\'s allowed',
                ),
                value: ui['webSearch'] == 'always',
                onChanged: (on) => set({'webSearch': on ? 'always' : null}),
              ),
              SwitchListTile(
                title: const T('Use memory'),
                subtitle: const T('Let models use what they remember'),
                value: ui['memory'] != false,
                onChanged: (on) => set({'memory': on}),
              ),
              SwitchListTile(
                title: const T('Suggest follow-ups'),
                subtitle: const T('Offer follow-up questions after replies'),
                value: ui['autoFollowUps'] != false,
                onChanged: (on) => set({'autoFollowUps': on}),
              ),
              SwitchListTile(
                title: const T('Temporary chat by default'),
                subtitle: const T(
                  'New chats aren\'t saved unless you keep them',
                ),
                value: ui['temporaryChatByDefault'] == true,
                onChanged: (on) => set({'temporaryChatByDefault': on}),
              ),
              SwitchListTile(
                title: const T('Edit suggestions first'),
                subtitle: const T(
                  'Tapping a suggested prompt puts it in the chat box',
                ),
                value: ui['insertSuggestionPrompt'] == true,
                onChanged: (on) => set({'insertSuggestionPrompt': on}),
              ),
              SwitchListTile(
                title: const T('Keep follow-up suggestions'),
                subtitle: const T('Under every reply, not just the last'),
                value: ui['keepFollowUpPrompts'] == true,
                onChanged: (on) => set({'keepFollowUpPrompts': on}),
              ),
              SwitchListTile(
                title: const T('Edit follow-ups first'),
                subtitle: const T(
                  'Tapping a follow-up puts it in the chat box',
                ),
                value: ui['insertFollowUpPrompt'] == true,
                onChanged: (on) => set({'insertFollowUpPrompt': on}),
              ),
              SwitchListTile(
                title: const T('Format your messages'),
                subtitle: const T('Show Markdown in what you send'),
                value: ui['renderMarkdownInUserMessages'] != false,
                onChanged: (on) => set({'renderMarkdownInUserMessages': on}),
              ),
              SwitchListTile(
                title: const T('Fold code blocks'),
                subtitle: const T('Code in replies starts folded'),
                value: ui['collapseCodeBlocks'] == true,
                onChanged: (on) => set({'collapseCodeBlocks': on}),
              ),
              SwitchListTile(
                title: const T('Open steps'),
                subtitle: const T('Thinking and tool steps start unfolded'),
                value: ui['expandDetails'] == true,
                onChanged: (on) => set({'expandDetails': on}),
              ),
              SwitchListTile(
                title: const T('Copy replies'),
                subtitle: const T('Copy each finished reply to the clipboard'),
                value: ui['responseAutoCopy'] == true,
                onChanged: (on) => set({'responseAutoCopy': on}),
              ),
              SwitchListTile(
                title: const T('Vibrate when done'),
                subtitle: const T('A light tap when a reply finishes'),
                value: ui['hapticFeedback'] == true,
                onChanged: (on) => set({'hapticFeedback': on}),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: const T('Archived chats'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const ArchivedChatsScreen(),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: const T('Archive all chats'),
                onTap: () => act(
                  'Archive all chats?',
                  'They move to Archived chats, where you can bring them back.',
                  'Archive all',
                  ref.read(settingsApiProvider).archiveAll,
                  'All chats archived',
                ),
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_forever_outlined,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: T(
                  'Delete all chats',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                subtitle: T(
                  'Removes every chat from the server',
                  style: TextStyle(color: muted),
                ),
                onTap: () => act(
                  'Delete all chats?',
                  'Every chat is deleted from the server. This can\'t be '
                      'undone.',
                  'Delete all',
                  ref.read(settingsApiProvider).deleteAllChats,
                  'All chats deleted',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final archivedChatsProvider = FutureProvider(
  (ref) => ref.watch(settingsApiProvider).archived(),
);

class ArchivedChatsScreen extends ConsumerWidget {
  const ArchivedChatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(archivedChatsProvider);
    final muted = context.nexus.muted;
    Future<void> restore(String id) async {
      try {
        await ref.read(clientProvider).toggleArchive(id);
      } catch (e) {
        if (context.mounted) _say(context, '$e');
      }
      ref.invalidate(archivedChatsProvider);
      refreshChatLists(ref.invalidate);
    }

    return Scaffold(
      appBar: AppBar(
        title: const T('Archived chats'),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                await ref.read(settingsApiProvider).unarchiveAll();
              } catch (e) {
                if (context.mounted) _say(context, '$e');
              }
              ref.invalidate(archivedChatsProvider);
              refreshChatLists(ref.invalidate);
            },
            child: const T('Restore all'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(archivedChatsProvider.future),
        child: list.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load archived chats.\n$e'),
              ),
            ],
          ),
          data: (chats) => ListView(
            children: [
              if (chats.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: T(
                    'No archived chats.',
                    style: TextStyle(color: muted),
                  ),
                ),
              for (final c in chats)
                ListTile(
                  title: Text(c.title),
                  subtitle: Text(
                    MaterialLocalizations.of(context)
                        .formatMediumDate(c.updatedAt),
                    style: TextStyle(color: muted),
                  ),
                  onTap: () {
                    ref.read(chatControllerProvider.notifier).open(c.id);
                    Navigator.of(context).popUntil((r) => r.isFirst);
                  },
                  trailing: IconButton(
                    tooltip: tr('Restore'),
                    onPressed: () => restore(c.id),
                    icon: const Icon(Icons.unarchive_outlined),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Memory ----

class MemoriesScreen extends ConsumerWidget {
  const MemoriesScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [Memory? m]) async {
    final text = TextEditingController(text: m?.content ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(m == null ? 'Add memory' : 'Edit memory'),
        content: TextField(
          controller: text,
          autofocus: true,
          minLines: 2,
          maxLines: 8,
          decoration: InputDecoration(
            hintText: tr('Something models should remember about you'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const T('Save'),
          ),
        ],
      ),
    );
    final content = text.text.trim();
    if (ok != true || content.isEmpty) return;
    final api = ref.read(settingsApiProvider);
    try {
      if (m == null) {
        await api.addMemory(content);
      } else {
        await api.updateMemory(m.id, content);
      }
    } catch (e) {
      if (context.mounted) _say(context, '$e');
    }
    ref.invalidate(memoriesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(memoriesProvider);
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const T('Memory'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (_) async {
              if (!await _confirm(
                context,
                'Clear all memories?',
                'Models forget everything they remember about you.',
                'Clear',
              )) {
                return;
              }
              try {
                await ref.read(settingsApiProvider).clearMemories();
              } catch (e) {
                if (context.mounted) _say(context, '$e');
              }
              ref.invalidate(memoriesProvider);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: T('Clear all')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: tr('Add memory'),
        onPressed: () => _edit(context, ref),
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(memoriesProvider.future),
        child: list.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn\'t load memories.\n$e'),
              ),
            ],
          ),
          data: (items) => ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: T(
                    'Nothing remembered yet. Models add memories as you '
                    'chat, or tap + to add one.',
                    style: TextStyle(color: muted),
                  ),
                ),
              for (final m in items)
                ListTile(
                  title: Text(m.content),
                  subtitle: Text(
                    [
                      if (m.path != null && m.path!.isNotEmpty) m.path!,
                      MaterialLocalizations.of(context)
                          .formatMediumDate(m.updated),
                    ].join(' · '),
                    style: TextStyle(color: muted),
                  ),
                  onTap: () => _edit(context, ref, m),
                  trailing: IconButton(
                    tooltip: tr('Delete'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      try {
                        await ref.read(settingsApiProvider).deleteMemory(m.id);
                      } catch (e) {
                        if (context.mounted) _say(context, '$e');
                      }
                      ref.invalidate(memoriesProvider);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
