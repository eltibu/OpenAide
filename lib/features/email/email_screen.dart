import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_screen.dart' show readingInset;
import '../chat/request_options.dart';
import '../studio/ai_sheet.dart';
import '../studio/record_notes.dart' show dictate;
import '../studio/studio_doc.dart' show cleanAiText;
import 'email_agent.dart';

/// Nexus, set up to work with email as it works in any chat.
final emailAgentProvider = FutureProvider<EmailAgent>((ref) async {
  final model = await ref.watch(defaultModelProvider.future);
  if (model == null) throw const EmailAgentError('No model to ask');
  final models = await ref.watch(modelsProvider.future);
  Future<Map<String, dynamic>?> optional(
    FutureProvider<Map<String, dynamic>> p,
  ) async {
    try {
      return await ref.watch(p.future);
    } catch (_) {
      return null;
    }
  }

  return EmailAgent(
    ref.watch(clientProvider),
    model: model,
    options: requestOptions(
      models.where((m) => m.id == model).firstOrNull,
      await optional(userSettingsProvider),
      await optional(serverConfigProvider),
    ),
  );
});

/// A folder's emails: the phone's copy shows at once, then the one kept
/// on the server, and Nexus checks for new ones only when the last check
/// is old (pulling down always checks). A check that fails leaves the
/// list as it was.
class EmailFolder {
  const EmailFolder({
    this.emails = const [],
    this.loaded = false,
    this.checking = false,
    this.checkedAt,
    this.error,
  });
  final List<Email> emails;

  /// The kept emails have been read (an empty list means none yet).
  final bool loaded;
  final bool checking;
  final DateTime? checkedAt;
  final String? error;

  EmailFolder copyWith({
    List<Email>? emails,
    bool? loaded,
    bool? checking,
    DateTime? checkedAt,
    String? error,
  }) => EmailFolder(
    emails: emails ?? this.emails,
    loaded: loaded ?? this.loaded,
    checking: checking ?? this.checking,
    checkedAt: checkedAt ?? this.checkedAt,
    error: error,
  );
}

class EmailFolderNotifier extends Notifier<EmailFolder> {
  EmailFolderNotifier(this.folder);
  final String folder;

  @override
  EmailFolder build() {
    Future.microtask(_start);
    return const EmailFolder();
  }

  Future<void> _start() async {
    final phone = await const EmailCache().read();
    if (!state.loaded && (phone[folder] as List? ?? const []).isNotEmpty) {
      state = EmailFolder(
        emails: keptIn(phone, folder),
        loaded: true,
        checkedAt: checkedIn(phone, folder),
      );
    }
    try {
      final agent = await ref.read(emailAgentProvider.future);
      final kept = await agent.kept(folder);
      final checked = await agent.checkedAt(folder);
      if (!state.checking) {
        state = EmailFolder(
          emails: kept.isEmpty ? state.emails : kept,
          loaded: true,
          checkedAt: checked ?? state.checkedAt,
        );
      }
    } catch (_) {
      state = state.copyWith(loaded: true);
    }
    if (needsCheck(state.checkedAt)) await check();
  }

  /// Asks Nexus for new mail and adds it to the list.
  Future<void> check() async {
    if (state.checking) return;
    state = state.copyWith(checking: true);
    try {
      final agent = await ref.read(emailAgentProvider.future);
      final emails = await agent.check(folder);
      state = EmailFolder(
        emails: emails,
        loaded: true,
        checkedAt: DateTime.now(),
      );
    } catch (e) {
      state = state.copyWith(loaded: true, checking: false, error: '$e');
    }
  }

  /// Shows [id] as read or unread right away.
  void showRead(String id, bool read) {
    state = state.copyWith(
      emails: [
        for (final e in state.emails)
          e.id == id ? e.copyWith(unread: !read) : e,
      ],
      error: state.error,
    );
  }
}

final emailFolderProvider =
    NotifierProvider.family<EmailFolderNotifier, EmailFolder, String>(
      EmailFolderNotifier.new,
    );

/// Marks [e] read (or unread) in every list and keeps it on the server.
Future<void> markRead(WidgetRef ref, Email e, {bool read = true}) async {
  for (final folder in ['inbox', 'sent']) {
    if (ref.exists(emailFolderProvider(folder))) {
      ref.read(emailFolderProvider(folder).notifier).showRead(e.id, read);
    }
  }
  try {
    await (await ref.read(emailAgentProvider.future)).setRead(e, read: read);
  } catch (_) {
    // Shown now; kept on the phone until the server can be reached.
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

String _when(BuildContext context, DateTime? t) {
  if (t == null) return '';
  final l = MaterialLocalizations.of(context);
  final now = DateTime.now();
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return l.formatTimeOfDay(TimeOfDay.fromDateTime(t));
  }
  return l.formatShortMonthDay(t);
}

/// Counts the seconds while Nexus works, so a wait never looks stuck.
class _Waiting extends StatefulWidget {
  const _Waiting(this.text);
  final String text;

  @override
  State<_Waiting> createState() => _WaitingState();
}

class _WaitingState extends State<_Waiting> {
  final _watch = Stopwatch()..start();
  late final Timer _tick = Timer.periodic(
    const Duration(seconds: 1),
    (_) => setState(() {}),
  );

  @override
  void initState() {
    super.initState();
    _tick;
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            '${widget.text} ${_watch.elapsed.inSeconds}s',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.nexus.muted),
          ),
        ],
      ),
    ),
  );
}

/// Email as Nexus sees it: the inbox with a note from Nexus on each
/// message, what was sent, and replies written with AI help.
class EmailScreen extends ConsumerWidget {
  const EmailScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Email'),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Inbox'),
            Tab(text: 'Sent'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const _SearchScreen()),
            ),
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => const ReplyEditor()),
        ),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Write'),
      ),
      body: const TabBarView(
        children: [
          _EmailList(folder: 'inbox'),
          _EmailList(folder: 'sent'),
        ],
      ),
    ),
  );
}

class _EmailList extends ConsumerWidget {
  const _EmailList({required this.folder});
  final String folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(emailFolderProvider(folder));
    final notifier = ref.read(emailFolderProvider(folder).notifier);
    final muted = context.nexus.muted;
    final emails = box.emails;
    final waitText = folder == 'sent'
        ? 'OpenAide is reading what was sent…'
        : 'OpenAide is checking your inbox…';
    return RefreshIndicator(
      onRefresh: notifier.check,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          readingInset(context, 0),
          0,
          readingInset(context, 0),
          96,
        ),
        children: [
          if (box.checking && emails.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2)
          else if (box.checkedAt != null && emails.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Checked ${_ago(box.checkedAt!)}. Pull down to check again.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ),
          if (box.error != null)
            MaterialBanner(
              content: Text(
                emails.isEmpty
                    ? 'Couldn\'t get your email.\n\n${box.error}'
                    : 'Couldn\'t check for new email. These are the ones '
                          'kept from before.\n\n${box.error}',
              ),
              actions: [
                TextButton(
                  onPressed: notifier.check,
                  child: const Text('Try again'),
                ),
              ],
            ),
          if (emails.isEmpty && (box.checking || !box.loaded))
            SizedBox(height: 320, child: _Waiting(waitText))
          else if (emails.isEmpty && box.error == null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Nothing here.', style: TextStyle(color: muted)),
            ),
          for (final (i, e) in emails.indexed) ...[
            if (i > 0) const Divider(height: 1),
            EmailTile(email: e, sent: folder == 'sent'),
          ],
        ],
      ),
    );
  }
}

class EmailTile extends ConsumerWidget {
  const EmailTile({super.key, required this.email, this.sent = false});
  final Email email;
  final bool sent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = context.nexus.muted;
    final scheme = Theme.of(context).colorScheme;
    final who = sent ? 'To: ${email.to}' : email.fromName;
    final bold = email.unread ? FontWeight.w700 : FontWeight.w500;
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => EmailView(email: email)),
      ),
      onLongPress: () {
        unawaited(markRead(ref, email, read: email.unread));
        _say(context, email.unread ? 'Marked read' : 'Marked unread');
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (email.unread)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(Icons.circle, size: 8, color: scheme.primary),
                  ),
                Expanded(
                  child: Text(
                    who,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: bold),
                  ),
                ),
                Text(
                  _when(context, email.date),
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              email.subject.isEmpty ? '(no subject)' : email.subject,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: bold),
            ),
            if (email.snippet.isNotEmpty)
              Text(
                email.snippet,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: muted),
              ),
            if (email.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.auto_awesome, size: 14, color: scheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        email.note,
                        style: TextStyle(
                          color: scheme.primary,
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SearchScreen extends ConsumerStatefulWidget {
  const _SearchScreen();

  @override
  ConsumerState<_SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<_SearchScreen> {
  Future<List<Email>>? _found;

  void _search(String q) {
    if (q.trim().isEmpty) return;
    setState(() {
      _found = ref
          .read(emailAgentProvider.future)
          .then(
            (a) async => withReadState(
              await a.list(query: q.trim()),
              await a.readMarks(),
            ),
          );
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: TextField(
        autofocus: true,
        textInputAction: TextInputAction.search,
        onSubmitted: _search,
        decoration: const InputDecoration(
          hintText: 'Who, what, or "unread from this week"',
          border: InputBorder.none,
        ),
      ),
    ),
    body: _found == null
        ? const SizedBox()
        : FutureBuilder<List<Email>>(
            future: _found,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const _Waiting('OpenAide is searching your email…');
              }
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Couldn\'t search.\n\n${snap.error}'),
                );
              }
              final emails = snap.data!;
              return emails.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Nothing found.'),
                    )
                  : ListView.separated(
                      itemCount: emails.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) => EmailTile(email: emails[i]),
                    );
            },
          ),
  );
}

/// One email: its thread, what Nexus makes of it, and the reply it would
/// send.
class EmailView extends ConsumerStatefulWidget {
  const EmailView({super.key, required this.email});
  final Email email;

  @override
  ConsumerState<EmailView> createState() => _EmailViewState();
}

class _EmailViewState extends ConsumerState<EmailView> {
  late Future<OpenedEmail> _opened = _open();

  @override
  void initState() {
    super.initState();
    // Opening it reads it; kept on the server so it stays read everywhere.
    if (widget.email.unread) {
      Future.microtask(() => markRead(ref, widget.email));
    }
  }

  /// Shows what Nexus said when it was opened before; [fresh] asks again.
  Future<OpenedEmail> _open({bool fresh = false}) async {
    final agent = await ref.read(emailAgentProvider.future);
    if (!fresh) {
      final kept = await agent.keptOpen(widget.email);
      if (kept != null) return kept;
    }
    return agent.openAndKeep(widget.email);
  }

  Future<void> _reply(OpenedEmail o, {String text = ''}) async {
    final sent = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ReplyEditor(replyTo: o, text: text),
      ),
    );
    if (sent == true && mounted) {
      unawaited(ref.read(emailFolderProvider('sent').notifier).check());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = context.nexus.muted;
    final e = widget.email;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          e.subject.isEmpty ? '(no subject)' : e.subject,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Mark as unread',
            icon: const Icon(Icons.mark_email_unread_outlined),
            onPressed: () {
              unawaited(markRead(ref, e, read: false));
              Navigator.pop(context);
            },
          ),
          IconButton(
            tooltip: 'Ask OpenAide to open it again',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _opened = _open(fresh: true)),
          ),
        ],
      ),
      body: FutureBuilder<OpenedEmail>(
        future: _opened,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _Waiting('OpenAide is opening it…');
          }
          if (snap.hasError) {
            return ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text('Couldn\'t open it.\n\n${snap.error}'),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: () => setState(() => _opened = _open()),
                    child: const Text('Try again'),
                  ),
                ),
              ],
            );
          }
          final o = snap.data!;
          return ListView(
            padding: EdgeInsets.fromLTRB(
              readingInset(context, 12),
              8,
              readingInset(context, 12),
              32,
            ),
            children: [
              Text(
                e.subject.isEmpty ? '(no subject)' : e.subject,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              if (o.summary.isNotEmpty)
                Card(
                  elevation: 0,
                  color: scheme.primaryContainer.withValues(alpha: 0.4),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 18,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(o.summary)),
                      ],
                    ),
                  ),
                ),
              for (final m in o.messages)
                Card(
                  elevation: 0,
                  color: scheme.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                m.from,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Text(
                              _when(context, m.date),
                              style: TextStyle(color: muted, fontSize: 12),
                            ),
                          ],
                        ),
                        if (m.to.isNotEmpty)
                          Text(
                            'To: ${m.to}',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                        const SizedBox(height: 8),
                        SelectableText(m.body),
                      ],
                    ),
                  ),
                ),
              if (o.suggestedReply.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'OpenAide would reply',
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: muted),
                ),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: scheme.outlineVariant),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(o.suggestedReply),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.tonal(
                            onPressed: () => _reply(o, text: o.suggestedReply),
                            child: const Text('Use this reply'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _reply(o),
                icon: const Icon(Icons.reply),
                label: const Text('Reply'),
              ),
            ],
          );
        },
      ),
    );
  }
}

const _replySuggestions = [
  'Make it shorter',
  'Make it more formal',
  'Make it friendlier',
  'Say yes politely',
  'Say no politely',
  'Fix spelling and grammar',
  'Translate to Spanish',
  'Translate to English',
];

/// Writes a reply (or a new email) with AI help, then has Nexus send it.
class ReplyEditor extends ConsumerStatefulWidget {
  const ReplyEditor({super.key, this.replyTo, this.text = ''});

  /// Null for a new email.
  final OpenedEmail? replyTo;
  final String text;

  @override
  ConsumerState<ReplyEditor> createState() => _ReplyEditorState();
}

class _ReplyEditorState extends ConsumerState<ReplyEditor> {
  late final _body = TextEditingController(text: widget.text);
  final _to = TextEditingController();
  final _subject = TextEditingController();
  bool _all = false;
  bool _sending = false;

  bool get _isReply => widget.replyTo != null;

  String get _context {
    final o = widget.replyTo;
    if (o == null) {
      return 'A new email to ${_to.text} about "${_subject.text}".';
    }
    final last = o.messages.isEmpty ? null : o.messages.last;
    return 'A reply to this email from ${o.email.from}, subject '
        '"${o.email.subject}":\n\n${last?.body ?? o.email.snippet}';
  }

  Stream<String> _write(String instruction) async* {
    final model = await ref.read(defaultModelProvider.future);
    if (model == null) throw 'No model to write with';
    yield* ref
        .read(clientProvider)
        .streamCompletion(
          model: model,
          messages: [
            {
              'role': 'system',
              'content':
                  'You write emails for me. Answer with the email text only: '
                  'no subject line, no comments before or after it. Keep the '
                  "language of the email I'm answering unless asked to "
                  'translate.',
            },
            {
              'role': 'user',
              'content':
                  '$_context\n\n---\nMy draft so far:\n\n'
                  '${_body.text.trim().isEmpty ? '(empty)' : _body.text}\n\n'
                  '---\n$instruction',
            },
          ],
        );
  }

  Future<void> _ai() async {
    final result = await showModalBottomSheet<AiResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AiSheet(
        title: _body.text.trim().isEmpty
            ? 'Write it with AI'
            : 'Change it with AI',
        suggestions: _body.text.trim().isEmpty
            ? const [
                'Say yes politely',
                'Say no politely',
                'Ask for more details',
                'Say thanks',
              ]
            : _replySuggestions,
        dictate: (c) => dictate(c, ref.read(clientProvider)),
        run: _write,
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _body.text = cleanAiText(result.text));
  }

  Future<void> _dictate() async {
    final said = await dictate(context, ref.read(clientProvider));
    if (said == null || said.isEmpty || !mounted) return;
    final t = _body.text.trimRight();
    setState(() => _body.text = t.isEmpty ? said : '$t $said');
  }

  Future<void> _send() async {
    final text = _body.text.trim();
    if (text.isEmpty) return _say(context, 'Write something first');
    if (!_isReply &&
        (_to.text.trim().isEmpty || _subject.text.trim().isEmpty)) {
      return _say(context, 'Add who it is to and a subject');
    }
    final o = widget.replyTo;
    final to = o == null
        ? _to.text.trim()
        : (_all ? 'everyone on the thread' : o.email.from);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Send this email?'),
        content: Text('OpenAide sends it from your Gmail to $to.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _sending = true);
    try {
      final agent = await ref.read(emailAgentProvider.future);
      if (o != null) {
        await agent.reply(o.email, text, all: _all);
      } else {
        await agent.compose(
          to: _to.text.trim(),
          subject: _subject.text.trim(),
          text: text,
        );
      }
      if (!mounted) return;
      _say(context, 'Sent');
      ref.read(emailFolderProvider('sent').notifier).check();
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _say(context, 'Not sent: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.replyTo;
    return PopScope(
      canPop: !_sending,
      child: Scaffold(
        appBar: AppBar(
          title: Text(o == null ? 'New email' : 'Reply'),
          actions: [
            IconButton(
              tooltip: 'Copy',
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: _body.text)),
              icon: const Icon(Icons.copy_outlined),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send, size: 18),
                label: Text(_sending ? 'Sending…' : 'Send'),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            readingInset(context, 16),
            8,
            readingInset(context, 16),
            32,
          ),
          children: [
            if (o != null) ...[
              Text(
                'To: ${o.email.from}',
                style: TextStyle(color: context.nexus.muted),
              ),
              Text(
                'Re: ${o.email.subject}',
                style: TextStyle(color: context.nexus.muted),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Reply to everyone on it'),
                value: _all,
                onChanged: (v) => setState(() => _all = v),
              ),
            ] else ...[
              TextField(
                controller: _to,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'To'),
              ),
              TextField(
                controller: _subject,
                decoration: const InputDecoration(labelText: 'Subject'),
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _body,
              maxLines: null,
              minLines: 8,
              enabled: !_sending,
              decoration: const InputDecoration(
                hintText: 'Write your email, or let the AI write it',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _sending ? null : _ai,
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: Text(
                    _body.text.trim().isEmpty
                        ? 'Write with AI'
                        : 'Edit with AI',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _sending ? null : _dictate,
                  icon: const Icon(Icons.mic_none, size: 18),
                  label: const Text('Dictate'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
