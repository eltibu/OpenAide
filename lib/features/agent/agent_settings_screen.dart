/// Tools and skills: what models without a server can use. Switch the
/// built-in tools and skills on and off, add your own skills, MCP servers
/// and tool servers, pick a search engine, and see what was remembered and
/// noted.
library;

import '../../core/widgets/markdown_style.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../core/agent/mcp_client.dart';
import '../../core/agent/skills.dart';
import '../../core/agent/web_tools.dart';
import '../../core/theme.dart';
import 'agent_store.dart';
import 'agent_tools.dart';
import 'mcp_servers.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

Widget _header(BuildContext context, String text, {Widget? trailing}) =>
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          ?trailing,
        ],
      ),
    );

class AgentSettingsScreen extends ConsumerWidget {
  const AgentSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(agentStoreProvider);
    final store = ref.read(agentStoreProvider.notifier);
    final config = async.value;
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(title: const Text('Tools and skills')),
      body: config == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    'For models from your AI providers and models on this '
                    'phone. Chats on an Open WebUI server use the server\'s '
                    'own tools.',
                    style: TextStyle(color: muted),
                  ),
                ),
                for (final group in {
                  for (final t in builtInTools) t.group,
                }) ...[
                  _header(context, group),
                  for (final t in builtInTools.where((t) => t.group == group))
                    SwitchListTile(
                      title: Text(t.label),
                      subtitle: Text(t.description),
                      value: !config.offTools.contains(t.name),
                      onChanged: (on) => store.setToolOn(t.name, on),
                    ),
                  if (group == 'Web')
                    ListTile(
                      leading: const Icon(Icons.travel_explore),
                      title: const Text('Search engine'),
                      subtitle: Text(config.searchEngine.label),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => _SearchDialog(config: config),
                      ),
                    ),
                ],
                _header(
                  context,
                  'Skills',
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(Icons.add),
                    tooltip: 'Add a skill',
                    onSelected: (v) => v == 'new'
                        ? Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SkillEditorScreen(),
                            ),
                          )
                        : _importSkills(context, store),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'new', child: Text('Write a skill')),
                      PopupMenuItem(
                        value: 'import',
                        child: Text('Import .skill, .zip or SKILL.md'),
                      ),
                    ],
                  ),
                ),
                for (final s in config.allSkills)
                  SwitchListTile(
                    title: Text(s.name),
                    subtitle: Text(
                      s.builtIn ? s.description : 'Yours · ${s.description}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    value: !config.offSkills.contains(s.id),
                    onChanged: (on) => store.setSkillOn(s.id, on),
                    secondary: IconButton(
                      icon: const Icon(Icons.description_outlined),
                      tooltip: 'Open',
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SkillEditorScreen(skill: s),
                        ),
                      ),
                    ),
                  ),
                _header(
                  context,
                  'MCP servers',
                  trailing: IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Add an MCP server',
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const McpEditorScreen(),
                      ),
                    ),
                  ),
                ),
                if (config.mcpServers.isEmpty)
                  _hint(
                    context,
                    'Connect apps and services that have an MCP server '
                    '(Notion, GitHub, Zapier, your own...). Tap + and paste '
                    'its address.',
                  ),
                for (final s in config.mcpServers)
                  SwitchListTile(
                    title: Text('${s['name'] ?? s['url']}'),
                    subtitle: Text(
                      '${s['url']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    value: s['enabled'] != false,
                    onChanged: (on) =>
                        store.saveMcpServer({...s, 'enabled': on}),
                    secondary: IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: 'Edit',
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => McpEditorScreen(server: s),
                        ),
                      ),
                    ),
                  ),
                _header(
                  context,
                  'Tool servers (OpenAPI)',
                  trailing: IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Add a tool server',
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ToolServerEditorScreen(),
                      ),
                    ),
                  ),
                ),
                if (config.toolServers.isEmpty)
                  _hint(
                    context,
                    'OpenAPI tool servers, as in Open WebUI (for example '
                    'from mcpo). Tap + to add one.',
                  ),
                for (final s in config.toolServers)
                  SwitchListTile(
                    title: Text('${s['name'] ?? s['url']}'),
                    subtitle: Text(
                      '${s['url']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    value: s['enabled'] != false,
                    onChanged: (on) =>
                        store.saveToolServer({...s, 'enabled': on}),
                    secondary: IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: 'Edit',
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ToolServerEditorScreen(server: s),
                        ),
                      ),
                    ),
                  ),
                _header(context, 'Memory and notes'),
                SwitchListTile(
                  title: const Text('Use memory in chats'),
                  subtitle: const Text(
                    'What it remembered goes along with every chat',
                  ),
                  value: config.memoryOn,
                  onChanged: store.setMemoryOn,
                ),
                ListTile(
                  leading: const Icon(Icons.psychology_outlined),
                  title: const Text('Memory'),
                  subtitle: Text('${config.memories.length} remembered'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MemoryScreen()),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.sticky_note_2_outlined),
                  title: const Text('Notes'),
                  subtitle: Text('${config.notes.length} on this phone'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LocalNotesScreen()),
                  ),
                ),
              ],
            ),
    );
  }
}

Widget _hint(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
  child: Text(text, style: TextStyle(color: context.nexus.muted)),
);

Future<void> _importSkills(BuildContext context, AgentStore store) async {
  final picked = await FilePicker.pickFiles();
  if (picked.isEmpty) return;
  var count = 0;
  final problems = <String>[];
  for (final f in picked) {
    try {
      final found = skillsFromFile(f.name, await f.readAsBytes());
      if (found.isEmpty) problems.add('${f.name}: no skill in it');
      for (final s in found) {
        await store.saveSkill(s);
        count++;
      }
    } catch (e) {
      problems.add('${f.name}: $e');
    }
  }
  if (context.mounted) {
    _say(
      context,
      ['Imported $count skill${count == 1 ? '' : 's'}', ...problems].join('. '),
    );
  }
}

class _SearchDialog extends ConsumerStatefulWidget {
  const _SearchDialog({required this.config});
  final AgentConfig config;

  @override
  ConsumerState<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends ConsumerState<_SearchDialog> {
  late var _engine = widget.config.searchEngine;
  late final _key = TextEditingController(text: widget.config.searchKey);
  late final _url = TextEditingController(text: widget.config.searchUrl);

  @override
  void dispose() {
    _key.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Search engine'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RadioGroup<SearchEngine>(
          groupValue: _engine,
          onChanged: (v) => setState(() => _engine = v ?? _engine),
          child: Column(
            children: [
              for (final e in SearchEngine.values)
                RadioListTile<SearchEngine>(
                  value: e,
                  title: Text(e.label),
                  subtitle: e == SearchEngine.duckDuckGo
                      ? const Text('Free, no key')
                      : null,
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
        ),
        if (_engine.needsKey)
          TextField(
            controller: _key,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'API key'),
          ),
        if (_engine.needsUrl)
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Address',
              hintText: 'https://search.example.com',
            ),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () async {
          await ref
              .read(agentStoreProvider.notifier)
              .setSearch(
                _engine,
                url: _engine.needsUrl ? _url.text.trim() : null,
                key: _engine.needsKey ? _key.text : null,
              );
          if (context.mounted) Navigator.pop(context);
        },
        child: const Text('Save'),
      ),
    ],
  );
}

/// A skill: built-in ones to read (or copy and change), yours to edit.
class SkillEditorScreen extends ConsumerStatefulWidget {
  const SkillEditorScreen({super.key, this.skill});
  final Skill? skill;

  @override
  ConsumerState<SkillEditorScreen> createState() => _SkillEditorState();
}

class _SkillEditorState extends ConsumerState<SkillEditorScreen> {
  late final _name = TextEditingController(text: widget.skill?.name);
  late final _description = TextEditingController(
    text: widget.skill?.description,
  );
  late final _content = TextEditingController(text: widget.skill?.content);
  late bool _readOnly = widget.skill?.builtIn == true;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _content.text.trim().isEmpty) {
      _say(context, 'Give it a name and instructions');
      return;
    }
    final old = widget.skill;
    // A changed built-in is saved as yours under the same id, so it
    // replaces the built-in one.
    final id = old != null ? old.id : skillId(name);
    await ref
        .read(agentStoreProvider.notifier)
        .saveSkill(
          Skill(
            id: id,
            name: name,
            description: _description.text.trim(),
            content: _content.text.trim(),
          ),
          replacing: old?.id,
        );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.skill;
    final mine = s != null && !s.builtIn;
    return Scaffold(
      appBar: AppBar(
        title: Text(s == null ? 'New skill' : s.name),
        actions: [
          if (s != null)
            IconButton(
              tooltip: 'Copy as SKILL.md',
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: s.skillMd));
                _say(context, 'Copied');
              },
            ),
          if (mine)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await ref.read(agentStoreProvider.notifier).deleteSkill(s.id);
                if (context.mounted) Navigator.pop(context);
              },
            ),
          if (_readOnly)
            TextButton(
              onPressed: () => setState(() => _readOnly = false),
              child: const Text('Change'),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(onPressed: _save, child: const Text('Save')),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_readOnly)
            Text(
              'Comes with the app. Tap Change to make it your own.',
              style: TextStyle(color: context.nexus.muted),
            ),
          TextField(
            controller: _name,
            readOnly: _readOnly,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _description,
            readOnly: _readOnly,
            maxLines: null,
            decoration: const InputDecoration(
              labelText: 'When to use it',
              helperText: 'The model reads this to decide when it applies',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _content,
            readOnly: _readOnly,
            minLines: 10,
            maxLines: null,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Instructions (markdown)',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Adding or changing an MCP server, signing in, and its tools.
class McpEditorScreen extends ConsumerStatefulWidget {
  const McpEditorScreen({super.key, this.server});
  final Map<String, dynamic>? server;

  @override
  ConsumerState<McpEditorScreen> createState() => _McpEditorState();
}

class _McpEditorState extends ConsumerState<McpEditorScreen> {
  late final String _id = '${widget.server?['id'] ?? newAgentId()}';
  late final _name = TextEditingController(text: widget.server?['name']);
  late final _url = TextEditingController(text: widget.server?['url']);
  late final _headers = TextEditingController(
    text: serverHeaders(widget.server ?? const {}).entries
        .map((e) => '${e.key}: ${e.value}')
        .join('\n'),
  );
  late final _key = TextEditingController();
  late final _clientId = TextEditingController(
    text: widget.server?['client_id'],
  );
  late final _clientSecret = TextEditingController();
  late String _auth = '${widget.server?['auth'] ?? 'none'}';
  late final Set<String> _off = {
    ...?(widget.server?['off_tools'] as List?)?.map((e) => '$e'),
  };
  bool _busy = false;
  String? _status;
  List<McpTool>? _tools;

  @override
  void initState() {
    super.initState();
    final secret = ref.read(agentStoreProvider).value?.secretFor(_id) ?? {};
    _key.text = '${secret['key'] ?? ''}';
    if (widget.server != null) _test();
  }

  @override
  void dispose() {
    for (final c in [_name, _url, _headers, _key, _clientId, _clientSecret]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> get _server => {
    'id': _id,
    'name': _name.text.trim().isEmpty
        ? (Uri.tryParse(_url.text.trim())?.host ?? 'MCP server')
        : _name.text.trim(),
    'url': _url.text.trim(),
    'auth': _auth,
    'headers': {
      for (final line in _headers.text.split('\n'))
        if (line.contains(':'))
          line.substring(0, line.indexOf(':')).trim(): line
              .substring(line.indexOf(':') + 1)
              .trim(),
    },
    if (_clientId.text.trim().isNotEmpty) 'client_id': _clientId.text.trim(),
    'enabled': widget.server?['enabled'] ?? true,
    'off_tools': _off.toList(),
  };

  bool get _valid {
    final u = Uri.tryParse(_url.text.trim());
    return u != null && (u.scheme == 'https' || u.scheme == 'http');
  }

  Future<void> _saveOnly() async {
    final store = ref.read(agentStoreProvider.notifier);
    await store.saveMcpServer(_server);
    if (_auth == 'key') {
      final secret = (await store.current()).secretFor(_id);
      await store.setSecretFor(_id, {...secret, 'key': _key.text.trim()});
    }
  }

  Future<void> _test() async {
    if (!_valid) {
      setState(() => _status = 'Enter the server address (https://...)');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Connecting…';
    });
    try {
      await _saveOnly();
      final tools = await ref.read(mcpPoolProvider).listNow(_server);
      if (!mounted) return;
      setState(() {
        _tools = tools;
        _status = 'Connected: ${tools.length} tools';
      });
    } on McpException catch (e) {
      if (!mounted) return;
      setState(() {
        _tools = null;
        _status = e.needsSignIn && _auth == 'none'
            ? 'It wants a sign-in. Pick "Sign in" (or "Key") above.'
            : '$e';
      });
    } catch (e) {
      if (mounted) setState(() => _status = "Couldn't connect: $e");
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _signIn() async {
    if (!_valid) {
      setState(() => _status = 'Enter the server address (https://...)');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Signing in in the browser…';
    });
    try {
      await _saveOnly();
      final secret = await signInToMcp(
        _server,
        clientId: _clientId.text,
        clientSecret: _clientSecret.text,
      );
      await ref.read(agentStoreProvider.notifier).setSecretFor(_id, secret);
      if (!mounted) return;
      setState(() => _busy = false);
      await _test();
      return;
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final signedIn =
        ref.watch(agentStoreProvider).value?.secretFor(_id)['access'] != null;
    final muted = context.nexus.muted;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.server == null ? 'Add MCP server' : 'MCP server'),
        actions: [
          if (widget.server != null)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await ref
                    .read(agentStoreProvider.notifier)
                    .deleteMcpServer(_id);
                if (context.mounted) Navigator.pop(context);
              },
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy
                  ? null
                  : () async {
                      if (!_valid) {
                        setState(() => _status = 'Enter the server address');
                        return;
                      }
                      await _saveOnly();
                      if (context.mounted) Navigator.pop(context);
                    },
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Server address',
              hintText: 'https://example.com/mcp',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name (optional)'),
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'none', label: Text('No sign-in')),
              ButtonSegment(value: 'key', label: Text('Key')),
              ButtonSegment(value: 'oauth', label: Text('Sign in')),
            ],
            selected: {_auth},
            onSelectionChanged: (v) => setState(() => _auth = v.first),
          ),
          const SizedBox(height: 8),
          if (_auth == 'key')
            TextField(
              controller: _key,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Key or token',
                helperText: 'Sent as "Authorization: Bearer <key>"',
              ),
            ),
          if (_auth == 'oauth') ...[
            Text(
              signedIn
                  ? 'Signed in. Sign in again if it stops working.'
                  : 'You sign in on the service\'s own page in the browser.',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _signIn,
              icon: const Icon(Icons.login),
              label: Text(signedIn ? 'Sign in again' : 'Sign in'),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Client ID (only if the service asks)'),
              children: [
                TextField(
                  controller: _clientId,
                  decoration: const InputDecoration(labelText: 'Client ID'),
                ),
                TextField(
                  controller: _clientSecret,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Client secret (optional)',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Redirect address to register: http://localhost/callback '
                  '(any port)',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
          ],
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Extra headers'),
            children: [
              TextField(
                controller: _headers,
                maxLines: null,
                decoration: const InputDecoration(
                  hintText: 'X-Api-Key: abc123\nOne per line',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _test,
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Connect and list tools'),
              ),
              const SizedBox(width: 12),
              if (_busy)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_status!, style: TextStyle(color: muted)),
            ),
          if (_tools != null) ...[
            const SizedBox(height: 8),
            for (final t in _tools!)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.title ?? t.name),
                subtitle: Text(
                  t.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                value: !_off.contains(t.name),
                onChanged: (on) async {
                  setState(() => on ? _off.remove(t.name) : _off.add(t.name));
                  await ref
                      .read(agentStoreProvider.notifier)
                      .saveMcpServer(_server);
                },
              ),
          ],
        ],
      ),
    );
  }
}

/// Adding or changing an OpenAPI tool server.
class ToolServerEditorScreen extends ConsumerStatefulWidget {
  const ToolServerEditorScreen({super.key, this.server});
  final Map<String, dynamic>? server;

  @override
  ConsumerState<ToolServerEditorScreen> createState() =>
      _ToolServerEditorState();
}

class _ToolServerEditorState extends ConsumerState<ToolServerEditorScreen> {
  late final String _id = '${widget.server?['id'] ?? newAgentId()}';
  late final _name = TextEditingController(text: widget.server?['name']);
  late final _url = TextEditingController(text: widget.server?['url']);
  late final _path = TextEditingController(
    text: '${widget.server?['path'] ?? 'openapi.json'}',
  );
  late final _key = TextEditingController();
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _key.text =
        '${ref.read(agentStoreProvider).value?.secretFor(_id)['key'] ?? ''}';
  }

  @override
  void dispose() {
    for (final c in [_name, _url, _path, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> get _server => {
    'id': _id,
    'name': _name.text.trim().isEmpty
        ? (Uri.tryParse(_url.text.trim())?.host ?? 'Tool server')
        : _name.text.trim(),
    'url': _url.text.trim().replaceAll(RegExp(r'/+$'), ''),
    'path': _path.text.trim().isEmpty ? 'openapi.json' : _path.text.trim(),
    'key_set': _key.text.trim().isNotEmpty,
    'enabled': widget.server?['enabled'] ?? true,
  };

  Future<void> _save() async {
    final store = ref.read(agentStoreProvider.notifier);
    await store.saveToolServer(_server);
    await store.setSecretFor(
      _id,
      _key.text.trim().isEmpty ? null : {'key': _key.text.trim()},
    );
  }

  Future<void> _test() async {
    if (Uri.tryParse(_url.text.trim())?.host.isEmpty ?? true) {
      setState(() => _status = 'Enter the server address (https://...)');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Connecting…';
    });
    try {
      final n = await checkToolServer(_server, _key.text.trim());
      if (mounted) setState(() => _status = 'Connected: $n tools');
    } catch (e) {
      if (mounted) setState(() => _status = "Couldn't connect: $e");
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.server == null ? 'Add tool server' : 'Tool server'),
      actions: [
        if (widget.server != null)
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await ref.read(agentStoreProvider.notifier).deleteToolServer(_id);
              if (context.mounted) Navigator.pop(context);
            },
          ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton(
            onPressed: () async {
              if (Uri.tryParse(_url.text.trim())?.hasScheme != true) {
                setState(() => _status = 'Enter the server address');
                return;
              }
              await _save();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'https://tools.example.com',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _path,
          decoration: const InputDecoration(labelText: 'OpenAPI spec path'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name (optional)'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _key,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Key (optional)',
            helperText: 'Sent as "Authorization: Bearer <key>"',
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _test,
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('Test'),
            ),
            const SizedBox(width: 12),
            if (_status != null)
              Expanded(
                child: Text(
                  _status!,
                  style: TextStyle(color: context.nexus.muted),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}

/// What the model remembered, to read and delete.
class MemoryScreen extends ConsumerWidget {
  const MemoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(agentStoreProvider).value;
    final store = ref.read(agentStoreProvider.notifier);
    final items = [...?config?.memories].reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory'),
        actions: [
          IconButton(
            tooltip: 'Add',
            icon: const Icon(Icons.add),
            onPressed: () async {
              final text = await _ask(context, 'Remember', '');
              if (text != null && text.trim().isNotEmpty) {
                await store.remember(text);
              }
            },
          ),
          if (items.isNotEmpty)
            IconButton(
              tooltip: 'Forget everything',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Forget everything?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('Forget'),
                      ),
                    ],
                  ),
                );
                if (ok == true) await store.clearMemory();
              },
            ),
        ],
      ),
      body: items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Nothing yet. Say "remember that..." in a chat.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.nexus.muted),
                ),
              ),
            )
          : ListView(
              children: [
                for (final m in items)
                  ListTile(
                    title: Text('${m['text']}'),
                    trailing: IconButton(
                      tooltip: 'Forget',
                      icon: const Icon(Icons.close),
                      onPressed: () => store.forget('${m['id']}'),
                    ),
                  ),
              ],
            ),
    );
  }
}

Future<String?> _ask(BuildContext context, String title, String text) {
  final c = TextEditingController(text: text);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, maxLines: null),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, c.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  // c is not disposed: the dialog's text field still builds while it closes.
}

/// Notes the model saved on the phone.
class LocalNotesScreen extends ConsumerWidget {
  const LocalNotesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = [...?ref.watch(agentStoreProvider).value?.notes]
      ..sort((a, b) => (b['at'] as num? ?? 0).compareTo(a['at'] as num? ?? 0));
    return Scaffold(
      appBar: AppBar(title: const Text('Notes')),
      body: notes.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No notes yet. Ask in a chat: "save a note with...".',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.nexus.muted),
                ),
              ),
            )
          : ListView(
              children: [
                for (final n in notes)
                  ListTile(
                    title: Text('${n['title']}'),
                    subtitle: Text(
                      '${n['content']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => _NoteScreen(note: n)),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _NoteScreen extends ConsumerWidget {
  const _NoteScreen({required this.note});
  final Map<String, dynamic> note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${note['title']}'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: '${note['content']}'));
              _say(context, 'Copied');
            },
          ),
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final text = await _ask(
                context,
                'Edit note',
                '${note['content']}',
              );
              if (text == null) return;
              await ref
                  .read(agentStoreProvider.notifier)
                  .saveNote(
                    id: '${note['id']}',
                    title: '${note['title']}',
                    content: text,
                  );
              if (context.mounted) Navigator.pop(context);
            },
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await ref
                  .read(agentStoreProvider.notifier)
                  .deleteNote('${note['id']}');
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: MarkdownBlock(
          data: '${note['content']}',
          selectable: true,
          config: nexusMarkdown(context),
        ),
      ),
    );
  }
}
