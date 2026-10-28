/// Nexus without a server: chat with models from AI providers you signed
/// in to on the phone, with chats kept on the phone.
library;

import '../../core/widgets/search_field.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:uuid/uuid.dart';

import '../../core/agent/agent_loop.dart';
import '../../core/ai/ai_providers.dart';
import '../../core/models/chat.dart';
import '../../core/models/model_info.dart';
import '../../core/theme.dart';
import '../../core/widgets/nexus_logo.dart';
import '../agent/agent_settings_screen.dart';
import '../agent/agent_tools.dart';
import '../chat/reply_parts.dart';
import '../chat/reply_steps.dart';
import '../phone/phone_action_ui.dart';
import '../providers/ai_keys.dart';
import '../providers/local_models.dart';
import '../providers/local_models_screen.dart';
import '../providers/ai_providers_screen.dart';
import '../providers/provider_chat.dart';
import 'local_chats.dart';
import '../../core/widgets/markdown_style.dart';
import '../../core/i18n/app_strings.dart';

const _uuid = Uuid();

class StandaloneScreen extends ConsumerStatefulWidget {
  const StandaloneScreen({super.key});

  @override
  ConsumerState<StandaloneScreen> createState() => _StandaloneScreenState();
}

class _StandaloneScreenState extends ConsumerState<StandaloneScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Chat? _chat;
  String? _modelId;
  bool _streaming = false;
  String? _error;
  final _images = <String>[];
  StreamSubscription<AgentEvent>? _sub;
  Completer<void>? _running;

  @override
  void initState() {
    super.initState();
    lastStandaloneModel().then((id) {
      if (mounted && _modelId == null && id != null) {
        setState(() => _modelId = id);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<ModelInfo> get _models =>
      ref.read(providerModelsProvider).value ?? const [];

  /// The picked model if it's still available, else a sensible first one.
  String? _effectiveModel(List<ModelInfo> models) {
    if (models.isEmpty) return null;
    if (models.any((m) => m.id == _modelId)) return _modelId;
    const preferred = [
      'direct:anthropic:claude-sonnet',
      'direct:openrouter:anthropic/claude-sonnet',
      'direct:openai:gpt-5',
    ];
    for (final p in preferred) {
      final hit = models.where((m) => m.id.startsWith(p)).firstOrNull;
      if (hit != null) return hit.id;
    }
    return models.first.id;
  }

  void _newChat() {
    _stop();
    setState(() {
      _chat = null;
      _error = null;
      _images.clear();
    });
  }

  Future<void> _open(String id) async {
    _stop();
    final store = await ref.read(localChatStoreProvider.future);
    final chat = await store.load(id);
    if (!mounted || chat == null) return;
    setState(() {
      _chat = chat;
      _error = null;
      final last = chat.thread.lastWhere(
        (m) => m.role == 'assistant' && m.model != null,
        orElse: () => ChatMessage(id: '', role: 'assistant', content: ''),
      );
      if (last.model != null) _modelId = last.model;
    });
    _toBottom();
  }

  Future<void> _delete(ChatSummary c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const T('Delete chat?'),
        content: Text('"${c.title}" will be deleted from this phone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const T('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final store = await ref.read(localChatStoreProvider.future);
    await store.delete(c.id);
    ref.invalidate(localChatsProvider);
    if (_chat?.id == c.id) _newChat();
  }

  Future<void> _pickImage() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final name = file.name.toLowerCase();
    final type = name.endsWith('.png')
        ? 'image/png'
        : name.endsWith('.webp')
        ? 'image/webp'
        : name.endsWith('.gif')
        ? 'image/gif'
        : 'image/jpeg';
    setState(() => _images.add('data:$type;base64,${base64Encode(bytes)}'));
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final model = _effectiveModel(_models);
    if (_streaming || model == null || (text.isEmpty && _images.isEmpty)) {
      return;
    }
    final chat =
        _chat ??
        Chat(
          id: _uuid.v4(),
          title: _titleFrom(text.isNotEmpty ? text : 'Photo'),
          messages: {},
          models: [model],
        );
    final user = ChatMessage(
      id: _uuid.v4(),
      role: 'user',
      content: text,
      parentId: chat.currentId,
      extra: {
        'models': [model],
        if (_images.isNotEmpty)
          'files': [
            for (final (i, url) in _images.indexed)
              {'type': 'image', 'url': url, 'name': 'photo-${i + 1}'},
          ],
      },
    );
    chat
      ..models = [model]
      ..append(user);
    _input.clear();
    setState(() {
      _chat = chat;
      _images.clear();
    });
    unawaited(saveStandaloneModel(model));
    await _reply(chat, model);
  }

  Future<void> _reply(Chat chat, String model) async {
    final history = chat.thread;
    final reply = ChatMessage(
      id: _uuid.v4(),
      role: 'assistant',
      content: '',
      parentId: chat.currentId,
      model: model,
    );
    chat.append(reply);
    final running = _running = Completer<void>();
    setState(() {
      _streaming = true;
      _error = null;
    });
    _toBottom();
    final out = AgentOutput();
    try {
      final small = usesPromptTools(
        parseProviderModel(model)?.provider ?? AiProvider.openAi,
      );
      final kit = await buildAgentKitFor(
        ref,
        small: small,
        pickContact: (people) => pickContactSheet(context, people),
      );
      final stream = streamAgentReply(
        keys: await ref.read(aiKeysProvider.future),
        modelId: model,
        history: history,
        tools: kit.tools,
        system: kit.instructions,
      );
      final sub = _sub = stream.listen((e) {
        out.add(e);
        reply.content = out.content;
        reply.extra['output'] = out.output();
        if (mounted && identical(_chat, chat)) setState(() {});
        _toBottom(onlyIfNear: true);
      });
      await Future.any([sub.asFuture<void>(), running.future]);
      await sub.cancel();
    } catch (e) {
      reply.extra['error'] = {'content': '$e'};
      if (mounted && identical(_chat, chat)) setState(() => _error = '$e');
    }
    _sub = null;
    reply.content = out.content;
    reply.extra['output'] = out.output(done: true);
    reply.extra['done'] = true;
    try {
      final store = await ref.read(localChatStoreProvider.future);
      await store.save(chat);
      ref.invalidate(localChatsProvider);
    } catch (e) {
      _error ??= "Couldn't save this chat on the phone: $e";
    }
    if (mounted) setState(() => _streaming = false);
  }

  void _stop() {
    _running?.complete();
    _running = null;
  }

  Future<void> _retry() async {
    final chat = _chat;
    if (chat == null || _streaming) return;
    final thread = chat.thread;
    if (thread.isEmpty) return;
    // Ask again for the last message: a new reply next to the old one.
    final last = thread.last;
    if (last.role == 'assistant') chat.currentId = last.parentId;
    final model = _effectiveModel(_models);
    if (model == null) return;
    await _reply(chat, model);
  }

  void _toBottom({bool onlyIfNear = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      if (onlyIfNear && pos.maxScrollExtent - pos.pixels > 200) return;
      _scroll.jumpTo(pos.maxScrollExtent);
    });
  }

  Future<void> _pickModel(List<ModelInfo> models) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ModelSheet(models: models, selected: _modelId),
    );
    if (picked == null) return;
    setState(() => _modelId = picked);
    unawaited(saveStandaloneModel(picked));
  }

  Future<void> _connectServer() async {
    Navigator.pop(context); // the drawer
    await ref.read(standaloneModeProvider.notifier).set(false);
  }

  @override
  Widget build(BuildContext context) {
    final keys = ref.watch(aiKeysProvider).value ?? const {};
    // A provider key or a model on the phone is enough to chat.
    final canChat =
        keys.isNotEmpty ||
        (ref.watch(localPickerModelsProvider).value?.isNotEmpty ?? false);
    final modelsAsync = ref.watch(providerModelsProvider);
    final models = modelsAsync.value ?? const <ModelInfo>[];
    final model = _effectiveModel(models);
    final modelName = models.where((m) => m.id == model).firstOrNull?.name;
    return Scaffold(
      appBar: AppBar(
        title: !canChat
            ? const T('OpenAide')
            : TextButton(
                onPressed: models.isEmpty ? null : () => _pickModel(models),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        modelsAsync.isLoading && models.isEmpty
                            ? 'Loading models…'
                            : modelName ?? 'Pick a model',
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
        actions: [
          if (canChat)
            IconButton(
              tooltip: tr('New chat'),
              icon: const Icon(Icons.edit_square),
              onPressed: _newChat,
            ),
        ],
      ),
      drawer: _drawer(context),
      body: !canChat
          ? AiProviderList(intro: _welcome(context))
          : Column(
              children: [
                Expanded(child: _messages(context)),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                        TextButton(onPressed: _retry, child: const T('Retry')),
                      ],
                    ),
                  ),
                if (modelsAsync.hasValue && models.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: T(
                      "Your providers didn't list any models. Check your "
                      'keys in AI providers.',
                    ),
                  ),
                _composer(context, enabled: model != null),
              ],
            ),
    );
  }

  Widget _welcome(BuildContext context) => Column(
    children: [
      const SizedBox(height: 8),
      const NexusLogo(size: 72),
      const SizedBox(height: 12),
      T(
        'Sign in to an AI provider',
        style: Theme.of(context).textTheme.titleLarge,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 6),
      T(
        'Pick at least one to start chatting. OpenRouter is the quickest: '
        'one sign-in gives you models from every big AI company. Keys stay '
        'on this phone. Or download a model to run on the phone itself, '
        'offline (at the bottom).',
        textAlign: TextAlign.center,
        style: TextStyle(color: context.nexus.muted),
      ),
    ],
  );

  Widget _drawer(BuildContext context) {
    final chats = ref.watch(localChatsProvider).value ?? const [];
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              leading: const NexusLogo(size: 32),
              title: const T('OpenAide'),
              subtitle: const T('Chats saved on this phone'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_square),
              title: const T('New chat'),
              onTap: () {
                Navigator.pop(context);
                _newChat();
              },
            ),
            const Divider(height: 1),
            Expanded(
              child: chats.isEmpty
                  ? Center(
                      child: T(
                        'No chats yet',
                        style: TextStyle(color: context.nexus.muted),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final c in chats)
                          ListTile(
                            title: Text(
                              c.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            selected: c.id == _chat?.id,
                            onTap: () {
                              Navigator.pop(context);
                              _open(c.id);
                            },
                            onLongPress: () => _delete(c),
                          ),
                      ],
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.handyman_outlined),
              title: const T('Tools and skills'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AgentSettingsScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: const T('AI providers'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AiProvidersScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.phone_android),
              title: const T('Models on this phone'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LocalModelsScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const T('Connect an Open WebUI server'),
              subtitle: const T('For memory, tools, files and sync'),
              onTap: _connectServer,
            ),
          ],
        ),
      ),
    );
  }

  Widget _messages(BuildContext context) {
    final thread = _chat?.thread ?? const <ChatMessage>[];
    if (thread.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const NexusLogo(size: 64),
              const SizedBox(height: 12),
              T(
                'How can I help?',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: thread.length,
      itemBuilder: (context, i) =>
          _message(context, thread[i], last: i == thread.length - 1),
    );
  }

  Widget _message(BuildContext context, ChatMessage m, {required bool last}) {
    final images = [
      for (final a in attachmentsOf(m))
        if (a.dataUrl != null) a.dataUrl!,
    ];
    if (m.role == 'user') {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.fromLTRB(56, 4, 12, 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: context.nexus.userBubble,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final url in images)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      base64Decode(url.substring(url.indexOf(',') + 1)),
                      height: 160,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              if (m.content.isNotEmpty) SelectableText(m.content),
            ],
          ),
        ),
      );
    }
    final busy = last && _streaming;
    final groups = groupParts(replyParts(m, live: busy));
    final working =
        busy && groups.any((g) => g is List<StepPart> && g.any((s) => !s.done));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final g in groups)
            if (g is TextPart)
              MarkdownBlock(
                data: g.text,
                selectable: true,
                config: nexusMarkdown(context),
              )
            else
              ReplySteps(steps: g as List<StepPart>, live: busy),
          if (busy && !working && (groups.isEmpty || groups.last is! TextPart))
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (m.error != null && !(last && _error != null))
            Text(
              m.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (!busy && m.content.isNotEmpty)
            Row(
              children: [
                IconButton(
                  tooltip: tr('Copy'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: m.content)),
                ),
                if (last)
                  IconButton(
                    tooltip: tr('Regenerate'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: _retry,
                  ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    _models.where((x) => x.id == m.model).firstOrNull?.name ??
                        parseProviderModel(m.model)?.model ??
                        '',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: context.nexus.muted, fontSize: 12),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _composer(BuildContext context, {required bool enabled}) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Container(
        decoration: BoxDecoration(
          color: context.nexus.composer,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: context.nexus.composerBorder),
        ),
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_images.isNotEmpty)
              SizedBox(
                height: 72,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(4),
                  children: [
                    for (final (i, url) in _images.indexed)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.memory(
                                base64Decode(
                                  url.substring(url.indexOf(',') + 1),
                                ),
                                width: 64,
                                height: 64,
                                fit: BoxFit.cover,
                              ),
                            ),
                            Positioned(
                              right: 0,
                              top: 0,
                              child: GestureDetector(
                                onTap: () =>
                                    setState(() => _images.removeAt(i)),
                                child: const CircleAvatar(
                                  radius: 10,
                                  child: Icon(Icons.close, size: 14),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: tr('Add a photo'),
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  onPressed: enabled && !_streaming ? _pickImage : null,
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: enabled,
                    minLines: 1,
                    maxLines: 6,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: enabled ? 'Message' : 'Pick a model first',
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                if (_streaming)
                  IconButton.filled(
                    tooltip: tr('Stop'),
                    icon: const Icon(Icons.stop),
                    onPressed: () => setState(_stop),
                  )
                else
                  IconButton.filled(
                    tooltip: tr('Send'),
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: enabled ? _send : null,
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _ModelSheet extends StatefulWidget {
  const _ModelSheet({required this.models, required this.selected});
  final List<ModelInfo> models;
  final String? selected;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  String _query = '';
  AiProvider? _only;

  @override
  Widget build(BuildContext context) {
    final providers = {
      for (final m in widget.models)
        ?AiProvider.byId(m.raw['nexus_provider'] as String?),
    };
    final q = _query.trim().toLowerCase();
    final list = [
      for (final m in widget.models)
        if ((q.isEmpty || '${m.name} ${m.id}'.toLowerCase().contains(q)) &&
            (_only == null || m.raw['nexus_provider'] == _only!.id))
          m,
    ];
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: SearchField(
                hint: 'Search a model',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (providers.length > 1)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    for (final p in [null, ...providers])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(p?.label ?? 'All'),
                          selected: _only == p,
                          onSelected: (_) => setState(() => _only = p),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final m = list[i];
                  return ListTile(
                    title: Text(m.name),
                    subtitle: Text(
                      '${m.raw['owned_by'] ?? ''}'
                      '${m.capabilities['vision'] == true ? ' · sees photos' : ''}',
                    ),
                    trailing: m.id == widget.selected
                        ? const Icon(Icons.check, color: NexusColors.accent)
                        : null,
                    onTap: () => Navigator.pop(context, m.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _titleFrom(String text) {
  final line = text.trim().split('\n').first;
  return line.length <= 50 ? line : '${line.substring(0, 50).trimRight()}…';
}
