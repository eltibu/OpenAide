/// Settings > Terminal connections, as the web's Integrations > Open
/// Terminal: your own terminal servers (an Open Terminal at its own
/// address, with its key), kept with your settings on the server. The one
/// switched on shows in the menu beside the admin's, for its shell and
/// Files.
library;

import '../../core/widgets/empty_state.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import '../terminal/terminal_api.dart';
import 'settings_screen.dart';
import '../../core/i18n/app_strings.dart';

/// [list] with only the one at [index] switched on, as on the web.
List<Map<String, dynamic>> onlyEnabled(
  List<Map<String, dynamic>> list,
  int index,
) => [
  for (var i = 0; i < list.length; i++) {...list[i], 'enabled': i == index},
];

/// Whether the terminal at [url] answers with [key]: null when it does,
/// else what went wrong.
Future<String?> checkTerminal(String url, String key) async {
  try {
    await TerminalApi(
      OpenWebUiClient(baseUrl: url),
      TerminalServer(id: url, name: url, url: url, key: key.trim()),
    ).cwd().timeout(const Duration(seconds: 10));
    return null;
  } on ApiException catch (e) {
    return switch (e.statusCode) {
      0 => "Couldn't reach it: ${e.message}",
      401 || 403 => 'The key was refused.',
      _ => 'It answered ${e.statusCode}.',
    };
  } catch (e) {
    return "Couldn't reach it: $e";
  }
}

class TerminalConnectionsScreen extends ConsumerStatefulWidget {
  const TerminalConnectionsScreen({super.key});

  @override
  ConsumerState<TerminalConnectionsScreen> createState() =>
      _TerminalConnectionsScreenState();
}

class _TerminalConnectionsScreenState
    extends ConsumerState<TerminalConnectionsScreen> {
  bool _saving = false;

  Future<void> _save(List<Map<String, dynamic>> list) async {
    setState(() => _saving = true);
    try {
      await ref.read(settingsApiProvider).patchUi({userTerminalsKey: list});
      ref
        ..invalidate(uiSettingsProvider)
        ..invalidate(userSettingsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(uiSettingsProvider);
    final list = userTerminalConfigs(ui.value);
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: const T('Terminal connections'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            tooltip: tr('Add connection'),
            icon: const Icon(Icons.add),
            onPressed: ui.hasValue
                ? () async {
                    final added = await _edit(context, null);
                    if (added != null) {
                      // A new one is the one in use, as on the web.
                      await _save(onlyEnabled([...list, added], list.length));
                    }
                  }
                : null,
          ),
        ],
      ),
      body: ui.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text("Couldn't load: $e")),
        data: (_) => ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: T(
                'Your own Open Terminal servers, reached straight from this '
                'phone with their key. The one switched on shows in the menu '
                "next to the server's terminals, for its shell and Files.",
                style: TextStyle(color: muted),
              ),
            ),
            if (list.isEmpty)
              const EmptyState(
                icon: Icons.terminal,
                title: 'No terminal connections yet',
                message: 'Tap + to add one.',
              ),
            for (var i = 0; i < list.length; i++)
              ListTile(
                leading: const Icon(Icons.terminal),
                title: Text(
                  '${list[i]['name'] ?? ''}'.trim().isEmpty
                      ? '${list[i]['url']}'
                      : '${list[i]['name']}',
                ),
                subtitle: Text('${list[i]['url']}'),
                onTap: _saving
                    ? null
                    : () async {
                        final changed = await _edit(context, list[i]);
                        if (changed == null) return;
                        await _save([
                          for (var j = 0; j < list.length; j++)
                            if (j != i)
                              list[j]
                            else if (changed.isNotEmpty)
                              changed,
                        ]);
                      },
                trailing: Switch(
                  value: list[i]['enabled'] != false,
                  onChanged: _saving
                      ? null
                      : (on) => _save(
                          on
                              ? onlyEnabled(list, i)
                              : [
                                  for (var j = 0; j < list.length; j++)
                                    j == i
                                        ? {...list[j], 'enabled': false}
                                        : list[j],
                                ],
                        ),
                ),
              ),
            if (list.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: T(
                  'Tap a connection to edit or remove it.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Name, address and key; null when cancelled.
  Future<Map<String, dynamic>?> _edit(
    BuildContext context,
    Map<String, dynamic>? old,
  ) => showDialog<Map<String, dynamic>>(
    context: context,
    builder: (_) => _ConnectionDialog(old: old),
  );
}

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog({this.old});
  final Map<String, dynamic>? old;

  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  late final _name = TextEditingController(
    text: '${widget.old?['name'] ?? ''}',
  );
  late final _url = TextEditingController(text: '${widget.old?['url'] ?? ''}');
  late final _key = TextEditingController(text: '${widget.old?['key'] ?? ''}');
  bool _hide = true;
  bool _checking = false;
  String? _result;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  String get _address => _url.text.trim().replaceAll(RegExp(r'/+$'), '');

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.old == null ? 'Add connection' : 'Edit connection'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: tr('URL'),
              hintText: tr('http://192.168.1.10:8000'),
            ),
            onChanged: (_) => setState(() => _result = null),
          ),
          TextField(
            controller: _key,
            obscureText: _hide,
            decoration: InputDecoration(
              labelText: tr('Key'),
              suffixIcon: IconButton(
                tooltip: _hide ? 'Show' : 'Hide',
                icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _hide = !_hide),
              ),
            ),
          ),
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: tr('Name (optional)')),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                onPressed: _checking || _address.isEmpty
                    ? null
                    : () async {
                        setState(() => _checking = true);
                        final problem = await checkTerminal(
                          OpenWebUiClient.normalizeUrl(_address),
                          _key.text,
                        );
                        if (mounted) {
                          setState(() {
                            _checking = false;
                            _result = problem ?? 'Connected.';
                          });
                        }
                      },
                icon: _checking
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering),
                label: const T('Test'),
              ),
              if (_result != null)
                Expanded(
                  child: Text(
                    _result!,
                    style: TextStyle(color: context.nexus.muted),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      if (widget.old != null)
        TextButton(
          onPressed: () => Navigator.pop(context, <String, dynamic>{}),
          child: const T('Remove'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const T('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_address.isEmpty) return;
          Navigator.pop(context, <String, dynamic>{
            ...?widget.old,
            'url': OpenWebUiClient.normalizeUrl(_address),
            'key': _key.text.trim(),
            'name': _name.text.trim(),
            'path': widget.old?['path'] ?? '/openapi.json',
            'auth_type': 'bearer',
            'enabled': widget.old?['enabled'] ?? true,
            'config': widget.old?['config'] ?? const {},
          });
        },
        child: const T('Save'),
      ),
    ],
  );
}
