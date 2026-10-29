/// Settings > Interface: the web's Interface switches, saved to your
/// account so the web and the app share them.
library;

import '../chat/quick_actions.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../chat/chat_controller.dart' show userSettingsProvider;
import '../../core/auth/session.dart';
import 'settings_screen.dart' show settingsApiProvider, uiSettingsProvider;
import 'keyboard_shortcuts.dart';
import 'user_location.dart';
import '../../core/i18n/app_strings.dart';

/// A switch: the setting's key, its default, label and what it does.
typedef UiSwitch = (String key, bool start, String label, String help);

/// Grouped as on the web. Every one is saved to the account; the help says
/// where it only changes the web page.
const interfaceSwitches = <String, List<UiSwitch>>{
  'Chat': [
    (
      'regenerateMenu',
      true,
      'Regenerate menu',
      'Regenerate offers Try again, Add details, More concise or your own '
          'instructions. Off: one tap tries again.',
    ),
    (
      'showUsername',
      false,
      'Show your name',
      'Your name instead of "You" beside your messages.',
    ),
    (
      'chatFadeStreamingText',
      true,
      'Fade in streaming text',
      'New words fade in as a reply is written.',
    ),
    (
      'scrollOnBranchChange',
      true,
      'Scroll on branch change',
      'Jump to the reply when you switch between answers.',
    ),
    (
      'renderMarkdownInPreviews',
      true,
      'Format previews',
      'Show Markdown in chat and note previews.',
    ),
    (
      'copyFormatted',
      false,
      'Copy formatted text',
      'Copy keeps headings, lists and links when pasted elsewhere.',
    ),
    (
      'stylizedPdfExport',
      true,
      'Styled PDF export',
      'PDFs look like the chat, not plain text.',
    ),
    (
      'highContrastMode',
      false,
      'Accessibility mode',
      'Higher contrast on the web page.',
    ),
  ],
  'Message box': [
    (
      'largeTextAsFile',
      false,
      'Paste large text as file',
      'Pasting more than 1,000 characters attaches them as a text file.',
    ),
    (
      'richTextInput',
      true,
      'Rich text input',
      'Write with formatting in the message box.',
    ),
    (
      'showFormattingToolbar',
      false,
      'Formatting toolbar',
      'Bold, lists, headings and more above the message box.',
    ),
    (
      'insertPromptAsRichText',
      false,
      'Insert prompts as rich text',
      'Saved prompts keep their formatting.',
    ),
    (
      'promptAutocomplete',
      false,
      'Prompt autocompletion',
      'Suggests how to finish what you are typing.',
    ),
  ],
  'Images': [
    (
      'imageCompression',
      false,
      'Image compression',
      'Shrink photos to the size below before sending.',
    ),
    (
      'imageCompressionInChannels',
      true,
      'Compress images in channels',
      'Also shrink photos sent to channels.',
    ),
  ],
  'Terminal': [
    (
      'showFilesOnTerminalSelect',
      true,
      'Show files on terminal select',
      'Picking a terminal opens its files.',
    ),
    (
      'terminalPreviewAllowSameOrigin',
      false,
      'Terminal previews: same origin',
      'Let previewed pages from the terminal use your session.',
    ),
  ],
  'Artifacts and embeds': [
    (
      'iframeSandboxAllowScripts',
      true,
      'Allow scripts',
      'Artifacts and embeds can run JavaScript.',
    ),
    (
      'iframeSandboxAllowSameOrigin',
      false,
      'Allow same origin',
      'They can reach the server as you. Only for content you trust.',
    ),
    ('iframeSandboxAllowForms', true, 'Allow forms', 'They can send forms.'),
    (
      'iframeSandboxAllowDownloads',
      true,
      'Allow downloads',
      'They can save files.',
    ),
  ],
  'Voice': [
    (
      'showEmojiInCall',
      false,
      'Emoji in calls',
      'The model shows an emoji for how it feels while talking.',
    ),
  ],
  'Admin': [
    (
      'showUpdateToast',
      true,
      'Note new Open WebUI versions',
      'Admins: say so when a newer Open WebUI is out.',
    ),
    (
      'showChangelog',
      true,
      'Show "What\'s New" after updates',
      'Admins: open the release notes once after the server is updated.',
    ),
  ],
};

/// Switches the app already follows; the others change only the web page
/// until the app gets each feature, but are kept in step either way.
const appFollows = {
  'regenerateMenu',
  'largeTextAsFile',
  'imageCompression',
  'imageCompressionInChannels',
  'showFilesOnTerminalSelect',
  'showFormattingToolbar',
  'showUsername',
  'scrollOnBranchChange',
  'promptAutocomplete',
  'iframeSandboxAllowScripts',
  'iframeSandboxAllowSameOrigin',
  'showEmojiInCall',
  'showUpdateToast',
  'showChangelog',
  'terminalPreviewAllowSameOrigin',
};

class InterfaceSettings extends ConsumerWidget {
  const InterfaceSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(uiSettingsProvider);
    final muted = context.nexus.muted;
    Future<void> set(Map<String, dynamic> fields) async {
      try {
        await ref.read(settingsApiProvider).patchUi(fields);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$e')));
        }
      }
      ref.invalidate(uiSettingsProvider);
      ref.invalidate(userSettingsProvider);
    }

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(color: NexusColors.accent),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const T('Interface')),
      body: ui.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Couldn\'t load your settings.\n$e'),
        ),
        data: (ui) {
          final size = (ui['imageCompressionSize'] as Map?) ?? const {};
          Widget choice(
            String key,
            String start,
            String label,
            Map<String, String> options,
          ) => ListTile(
            title: Text(label),
            subtitle: Wrap(
              spacing: 6,
              children: [
                for (final o in options.entries)
                  ChoiceChip(
                    label: Text(o.value),
                    selected: (ui[key] ?? start) == o.key,
                    onSelected: (_) => set({key: o.key}),
                  ),
              ],
            ),
          );
          final scale = (ui['textScale'] as num?)?.toDouble();
          Future<void> setScale(double? v) => set({
            'textScale': v == null
                ? null
                : double.parse(v.clamp(1.0, 1.5).toStringAsFixed(2)),
          });
          return ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              heading('Display'),
              ListTile(
                title: const T('UI Scale'),
                subtitle: T(
                  'Makes all text in the app bigger, on top of the phone\'s '
                  'own font size.',
                  style: TextStyle(color: muted),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: tr('Decrease UI Scale'),
                      icon: const Icon(Icons.remove),
                      onPressed: scale == null || scale <= 1
                          ? null
                          : () => setScale(scale - 0.1),
                    ),
                    TextButton(
                      onPressed: () => setScale(scale == null ? 1.0 : null),
                      child: Text(
                        scale == null ? tr('Default') : '${scale}x',
                      ),
                    ),
                    IconButton(
                      tooltip: tr('Increase UI Scale'),
                      icon: const Icon(Icons.add),
                      onPressed: scale != null && scale >= 1.5
                          ? null
                          : () => setScale((scale ?? 1.0) + 0.1),
                    ),
                  ],
                ),
              ),
              SwitchListTile(
                title: const T('Display Chat Title in Tab'),
                subtitle: T(
                  'The open chat\'s title names the app in the phone\'s '
                  'recent apps.',
                  style: TextStyle(color: muted),
                ),
                value: ui['showChatTitleInTab'] != false,
                onChanged: (on) => set({'showChatTitleInTab': on}),
              ),
              choice('chatDirection', 'auto', 'Chat Direction', {
                'auto': tr('Auto'),
                'LTR': tr('LTR'),
                'RTL': tr('RTL'),
              }),
              SwitchListTile(
                title: const T('Chat Hover Previews'),
                subtitle: T(
                  'Press and hold a chat in the chat list to see its latest '
                  'messages.',
                  style: TextStyle(color: muted),
                ),
                value: ui['chatHoverPreview'] != false,
                onChanged: (on) => set({'chatHoverPreview': on}),
              ),
              SwitchListTile(
                title: const T('Ctrl+Enter to Send'),
                subtitle: T(
                  'With a keyboard attached, Enter makes a new line and '
                  'Ctrl+Enter sends. Off: Enter sends, Shift+Enter makes a '
                  'new line.',
                  style: TextStyle(color: muted),
                ),
                value: ui['ctrlEnterToSend'] == true,
                onChanged: (on) => set({'ctrlEnterToSend': on}),
              ),
              ListTile(
                title: const T('Keyboard shortcuts'),
                subtitle: T(
                  'For a Bluetooth or USB keyboard.',
                  style: TextStyle(color: muted),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const KeyboardShortcutsScreen(),
                  ),
                ),
              ),
              for (final group in interfaceSwitches.entries) ...[
                heading(group.key),
                for (final (key, start, label, help) in group.value)
                  SwitchListTile(
                    title: Text(label),
                    subtitle: Text(
                      appFollows.contains(key)
                          ? help
                          : '$help Web page for now.',
                      style: TextStyle(color: muted),
                    ),
                    value: ui[key] is bool ? ui[key] as bool : start,
                    onChanged: (on) => set({key: on}),
                  ),
                if (group.key == 'Chat') ...[
                  SwitchListTile(
                    title: const T('Allow User Location'),
                    subtitle: T(
                      'Models can use where you are ({{USER_LOCATION}}).',
                      style: TextStyle(color: muted),
                    ),
                    value: userLocationOn(ui),
                    onChanged: (on) async {
                      if (on) {
                        final messenger = ScaffoldMessenger.of(context);
                        String? where;
                        try {
                          where = await updateUserLocation(
                            ref.read(clientProvider),
                          );
                        } catch (_) {}
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              where == null
                                  ? "Couldn't get your location. Is it "
                                        'allowed for OpenAide?'
                                  : 'User location successfully retrieved.',
                            ),
                          ),
                        );
                        if (where == null) return;
                      }
                      await set({userLocationKey: on});
                    },
                  ),
                  SwitchListTile(
                    title: const T('Quick Actions'),
                    subtitle: T(
                      'Ask and Explain next to Copy when you select reply text.',
                      style: TextStyle(color: muted),
                    ),
                    value: ui['showFloatingActionButtons'] != false,
                    onChanged: (on) => set({'showFloatingActionButtons': on}),
                  ),
                  ListTile(
                    title: const T('Manage Quick Actions'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const QuickActionsScreen(),
                      ),
                    ),
                  ),
                ],
                if (group.key == 'Message box')
                  choice(
                    'defaultUploadContext',
                    'focused',
                    'Files you attach',
                    {'focused': 'Relevant parts', 'full': 'Entire document'},
                  ),
                if (group.key == 'Images' && ui['imageCompression'] == true)
                  ListTile(
                    title: const T('Largest size'),
                    subtitle: Text(
                      [
                        '${size['width'] ?? ''}'.isEmpty
                            ? 'any width'
                            : '${size['width']} wide',
                        '${size['height'] ?? ''}'.isEmpty
                            ? 'any height'
                            : '${size['height']} high',
                      ].join(', '),
                    ),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () async {
                      final picked = await _askSize(context, size);
                      if (picked != null) {
                        await set({'imageCompressionSize': picked});
                      }
                    },
                  ),
                if (group.key == 'Terminal')
                  choice(
                    'terminalFileDisplay',
                    'sidebar',
                    'Files a terminal shows',
                    {'sidebar': 'In the side panel', 'inline': 'In the chat'},
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

Future<Map<String, String>?> _askSize(BuildContext context, Map size) {
  final w = TextEditingController(text: '${size['width'] ?? ''}');
  final h = TextEditingController(text: '${size['height'] ?? ''}');
  return showDialog<Map<String, String>>(
    context: context,
    builder: (d) => AlertDialog(
      title: const T('Largest image size'),
      content: Row(
        children: [
          Expanded(
            child: TextField(
              controller: w,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('Width')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: h,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('Height')),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const T('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(d, {
            'width': w.text.trim(),
            'height': h.text.trim(),
          }),
          child: const T('Save'),
        ),
      ],
    ),
  );
}
