/// Admin > Visible controls: which controls people who aren't admins see,
/// as the web's Admin > Settings > Interface > Visibility. Hiding one keeps
/// its setting and the feature itself; admins always see everything.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';

/// The web's control ids (src/lib/utils/ui-visibility.ts) and their names.
const visibleControlGroups = <(String, String, List<(String, String)>)>[
  (
    'model_editor.capabilities.',
    'Capabilities',
    [
      ('vision', 'Vision'),
      ('file_upload', 'File Upload'),
      ('file_context', 'File Context'),
      ('web_search', 'Web Search'),
      ('image_generation', 'Image Generation'),
      ('code_interpreter', 'Code Interpreter'),
      ('terminal', 'Terminal'),
      ('usage', 'Usage'),
      ('citations', 'Citations'),
      ('status_updates', 'Status Updates'),
      ('memory', 'Memory'),
      ('builtin_tools', 'Builtin Tools'),
    ],
  ),
  (
    'model_editor.defaults.',
    'Default Features',
    [
      ('web_search', 'Web Search'),
      ('image_generation', 'Image Generation'),
      ('code_interpreter', 'Code Interpreter'),
    ],
  ),
  (
    'model_editor.tools.',
    'Builtin Tools',
    [
      ('time', 'Time & Calculation'),
      ('user_input', 'Ask User'),
      ('memory', 'Memory'),
      ('chats', 'Chat History'),
      ('notes', 'Notes'),
      ('knowledge', 'Knowledge Base'),
      ('files', 'Files'),
      ('channels', 'Channels'),
      ('notifications', 'Notifications'),
      ('web_search', 'Web Search'),
      ('image_generation', 'Image Generation'),
      ('code_interpreter', 'Code Interpreter'),
      ('tasks', 'Task Management'),
      ('automations', 'Automations'),
      ('calendar', 'Calendar'),
      ('subagents', 'Sub-agents'),
      ('skills', 'Skills'),
    ],
  ),
  (
    'chat.',
    'Chat',
    [
      ('capture', 'Capture'),
      ('compare', 'Compare text'),
      ('attach_webpage', 'Attach Webpage'),
      ('attach_files', 'Attach Files'),
      ('attach_notes', 'Attach Notes'),
      ('attach_knowledge', 'Attach Knowledge'),
      ('reference_chats', 'Reference Chats'),
      ('selected_tools', 'Selected tools'),
      ('selected_skills', 'Selected skills'),
      ('selected_filters', 'Selected filters'),
      ('selected_web_search', 'Selected web search'),
      ('selected_image_generation', 'Selected image generation'),
      ('selected_code_interpreter', 'Selected code interpreter'),
      ('status', '/status'),
      ('model_command', '/model'),
      ('settings_command', '/settings'),
      ('usage', 'Usage'),
      ('merge', 'Merge Responses'),
      ('code_preview', 'Preview'),
      ('fork', 'Fork chat'),
      ('artifacts', 'Artifacts'),
      ('archive', 'Archive'),
      ('tags', 'Tags'),
    ],
  ),
  (
    'models.',
    'Models',
    [('set_default', 'Set as default'), ('pin', 'Keep in Sidebar')],
  ),
  (
    'settings.',
    'Settings',
    [
      ('usage', 'Usage'),
      ('speech_to_text_engine', 'Speech-to-Text Engine'),
      ('text_to_speech_engine', 'Text-to-Speech Engine'),
      ('user_location', 'Allow User Location'),
      ('chat_bubble', 'Chat Bubble UI'),
      ('widescreen', 'Widescreen Mode'),
      ('floating_action_buttons', 'Floating Quick Actions'),
      ('rich_text_input', 'Rich Text Input for Chat'),
      ('large_text_as_file', 'Paste Large Text as File'),
      ('detect_artifacts', 'Detect Artifacts Automatically'),
      ('iframe_sandbox_allow_scripts', 'iframe Sandbox Allow Scripts'),
      ('iframe_sandbox_allow_same_origin', 'iframe Sandbox Allow Same Origin'),
      ('iframe_sandbox_allow_forms', 'iframe Sandbox Allow Forms'),
      ('iframe_sandbox_allow_downloads', 'iframe Sandbox Allow Downloads'),
    ],
  ),
];

/// The server's hidden controls, from /api/config (ui.visibility): only
/// hidden ones are listed, as false.
Map<String, bool> visibilityFrom(Map<String, dynamic>? config) {
  final ui = config?['ui'];
  final v = ui is Map ? ui['visibility'] : null;
  return {
    if (v is Map)
      for (final e in v.entries)
        if (e.value == false) '${e.key}': false,
  };
}

/// Whether a control shows for you: admins see everything, others what the
/// server hasn't hidden, as the web's isControlVisible.
bool controlVisible(WidgetRef ref, String id) =>
    ref.watch(sessionProvider).value?.user?['role'] == 'admin' ||
    visibilityFrom(ref.watch(serverConfigProvider).value)[id] != false;

class VisibleControlsScreen extends ConsumerStatefulWidget {
  const VisibleControlsScreen({super.key});

  @override
  ConsumerState<VisibleControlsScreen> createState() =>
      _VisibleControlsScreenState();
}

class _VisibleControlsScreenState extends ConsumerState<VisibleControlsScreen> {
  Map<String, bool>? _hidden;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final config = await ref.read(clientProvider).config();
      if (mounted) setState(() => _hidden = visibilityFrom(config));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _set(String id, bool visible) async {
    final before = Map<String, bool>.of(_hidden!);
    setState(() {
      if (visible) {
        _hidden!.remove(id);
      } else {
        _hidden![id] = false;
      }
      _saving = true;
    });
    try {
      await ref
          .read(clientProvider)
          .send(
            'POST',
            '/api/v1/configs/interface/visibility',
            body: {'visibility': _hidden},
          );
      ref.invalidate(serverConfigProvider);
    } catch (e) {
      if (mounted) {
        setState(() => _hidden = before);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${tr('Not saved')}: $e')));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final hidden = _hidden;
    final heading = Theme.of(context).textTheme.titleSmall
        ?.copyWith(color: Theme.of(context).colorScheme.primary);
    return Scaffold(
      appBar: AppBar(
        title: const T('Visible controls'),
        bottom: _saving
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: hidden == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!),
                    ),
            )
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: T(
                    'Choose which controls appear for users. Hiding a '
                    'control keeps its current setting and underlying '
                    'feature available. Administrators always see available '
                    'controls.',
                    style: TextStyle(color: context.nexus.muted),
                  ),
                ),
                for (final (prefix, group, controls)
                    in visibleControlGroups) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(tr(group), style: heading),
                  ),
                  for (final (id, label) in controls)
                    SwitchListTile(
                      title: Text(tr(label)),
                      value: hidden['$prefix$id'] != false,
                      onChanged: _saving
                          ? null
                          : (on) => _set('$prefix$id', on),
                    ),
                ],
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
