import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../../core/widgets/markdown_style.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_screen.dart' show readingInset;
import '../chat/request_options.dart';
import '../studio/ai_sheet.dart';
import '../studio/record_notes.dart' show dictate;
import '../studio/studio_doc.dart' show cleanAiText;
import '../accounts/accounts_screen.dart';
import '../accounts/mail_accounts.dart';
import 'direct_mail.dart';
import 'email_html.dart';
import 'email_agent.dart';

/// Said when there is neither an account on the phone nor a server.
const noMailAccount =
    'Add an email account to read and send mail here. Gmail, iCloud, '
    'Yahoo and most others work with an app password.';

/// Whose mail Email shows: [nexusMailSource] (through Nexus on the
/// server) or the address of an account the app reads itself.
final mailSourceProvider = FutureProvider<String>(
  (ref) async =>
      (await ref.watch(mailAccountsProvider.future)).current?.email ??
      nexusMailSource,
);

/// The mail Email shows: an account the app reads itself (no server
/// needed), or Nexus, set up to work with email as in any chat.
final emailAgentProvider = FutureProvider<MailSource>((ref) async {
  final account = (await ref.watch(mailAccountsProvider.future)).current;
  if (account != null) return DirectMail(account);
  if ((await ref.watch(sessionProvider.future)) == null) {
    throw const EmailAgentError(noMailAccount);
  }
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
    socket: ref.watch(chatSocketProvider),
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
    // A new list whenever Email switches whose mail it shows.
    final source = ref.watch(mailSourceProvider.select((s) => s.value));
    if (source != null) Future.microtask(() => _start(source));
    return const EmailFolder();
  }

  Future<void> _start(String source) async {
    final phone = source == nexusMailSource
        ? await const EmailCache().read()
        : await DirectMailStore(source).read();
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

  /// Takes [id] off the list right away (archived, deleted, spam).
  void drop(String id) {
    state = state.copyWith(
      emails: [
        for (final e in state.emails)
          if (e.id != id) e,
      ],
      error: state.error,
    );
  }

  /// Shows [id] starred or not right away.
  void showStar(String id, bool starred) {
    state = state.copyWith(
      emails: [
        for (final e in state.emails)
          e.id == id ? e.copyWith(starred: starred) : e,
      ],
      error: state.error,
    );
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

enum EmailAct { archive, trash, spam }

/// Archives, deletes or reports [e]: it leaves the lists at once and the
/// mail service is told in the background; if that fails it says so and
/// the list is checked again. Takes the [container] (not a widget's ref),
/// since the email's page is usually closed by then.
Future<void> actOn(
  ProviderContainer container,
  ScaffoldMessengerState messenger,
  Email e,
  EmailAct what,
) async {
  for (final folder in ['inbox', 'sent']) {
    if (container.exists(emailFolderProvider(folder))) {
      container.read(emailFolderProvider(folder).notifier).drop(e.id);
    }
  }
  final (doing, done) = switch (what) {
    EmailAct.archive => ('archive', 'Archived'),
    EmailAct.trash => ('delete', 'Deleted'),
    EmailAct.spam => ('report', 'Reported as spam'),
  };
  messenger.showSnackBar(SnackBar(content: Text(done)));
  try {
    final box = await container.read(emailAgentProvider.future);
    await switch (what) {
      EmailAct.archive => box.archive(e),
      EmailAct.trash => box.trash(e),
      EmailAct.spam => box.spam(e),
    };
  } catch (err) {
    messenger.showSnackBar(
      SnackBar(content: Text('Couldn\'t $doing "${e.subject}": $err')),
    );
    for (final folder in ['inbox', 'sent']) {
      if (container.exists(emailFolderProvider(folder))) {
        unawaited(container.read(emailFolderProvider(folder).notifier).check());
      }
    }
  }
}

/// Stars or unstars [e] everywhere it shows.
Future<void> starOn(
  ProviderContainer container,
  ScaffoldMessengerState messenger,
  Email e,
  bool starred,
) async {
  for (final folder in ['inbox', 'sent']) {
    if (container.exists(emailFolderProvider(folder))) {
      container
          .read(emailFolderProvider(folder).notifier)
          .showStar(e.id, starred);
    }
  }
  try {
    await (await container.read(emailAgentProvider.future))
        .setStarred(e, starred);
  } catch (err) {
    messenger.showSnackBar(SnackBar(content: Text('Couldn\'t star it: $err')));
  }
}

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
        title: const _SourceTitle(),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Inbox'),
            Tab(text: 'Sent'),
          ],
        ),
        actions: [
          const _SourceMenu(),
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
    final direct = ref.watch(mailSourceProvider).value != nexusMailSource;
    final waitText = direct
        ? (folder == 'sent' ? 'Getting what was sent…' : 'Checking your inbox…')
        : folder == 'sent'
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
          if (!direct) const _ConnectGmail(),
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
                box.error == noMailAccount
                    ? noMailAccount
                    : emails.isEmpty
                    ? 'Couldn\'t get your email.\n\n${box.error}'
                    : 'Couldn\'t check for new email. These are the ones '
                          'kept from before.\n\n${box.error}',
              ),
              actions: [
                if (box.error == noMailAccount)
                  FilledButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const AddMailAccount(),
                      ),
                    ),
                    child: const Text('Add an account'),
                  )
                else
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
            Dismissible(
              key: ValueKey(e.id),
              background: const _SwipeBack(
                icon: Icons.archive_outlined,
                label: 'Archive',
                start: true,
              ),
              secondaryBackground: const _SwipeBack(
                icon: Icons.delete_outline,
                label: 'Delete',
                start: false,
              ),
              onDismissed: (d) => actOn(
                ProviderScope.containerOf(context, listen: false),
                ScaffoldMessenger.of(context),
                e,
                d == DismissDirection.startToEnd
                    ? EmailAct.archive
                    : EmailAct.trash,
              ),
              child: EmailTile(email: e, sent: folder == 'sent'),
            ),
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
                if (email.starred)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.star,
                      size: 16,
                      color: Colors.amber.shade700,
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
                return const _Waiting('Searching your email…');
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
  late Email _email = widget.email;
  OpenedEmail? _o;
  Object? _error;

  /// Still being read: [_o] is what has come so far.
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    _load();
    // Opening it reads it, everywhere it shows.
    if (widget.email.unread) {
      Future.microtask(() => markRead(ref, widget.email));
    }
  }

  /// Shows the copy kept when it was opened (or listed) before at once;
  /// [fresh] fetches it again.
  Future<void> _load({bool fresh = false}) async {
    setState(() {
      _error = null;
      _reading = true;
      if (fresh) _o = null;
    });
    try {
      final box = await ref.read(emailAgentProvider.future);
      final kept = fresh ? null : await box.keptOpen(_email);
      final o =
          kept ??
          await box.openAndKeep(
            _email,
            // What OpenAide has read so far shows while it reads on.
            onProgress: (partial) {
              if (mounted) setState(() => _o = partial);
            },
          );
      if (mounted) setState(() => _o = o);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _write({
    bool all = false,
    bool forward = false,
    String text = '',
  }) async {
    final o = _o;
    if (o == null) return;
    final sent = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ReplyEditor(replyTo: o, text: text, all: all, forward: forward),
      ),
    );
    if (sent == true && mounted) {
      unawaited(ref.read(emailFolderProvider('sent').notifier).check());
    }
  }

  void _act(EmailAct what) {
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    unawaited(actOn(container, messenger, _email, what));
  }

  void _star() {
    final starred = !_email.starred;
    setState(() => _email = _email.copyWith(starred: starred));
    unawaited(
      starOn(
        ProviderScope.containerOf(context, listen: false),
        ScaffoldMessenger.of(context),
        _email,
        starred,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = _email;
    final o = _o;
    final first = o?.messages.firstOrNull;
    // One message with its own layout: shown whole, like Gmail does.
    final html = o != null && o.messages.length == 1 && first!.html.isNotEmpty
        ? first.html
        : null;
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'Archive',
            icon: const Icon(Icons.archive_outlined),
            onPressed: () => _act(EmailAct.archive),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _act(EmailAct.trash),
          ),
          IconButton(
            tooltip: 'Mark as unread',
            icon: const Icon(Icons.mark_email_unread_outlined),
            onPressed: () {
              unawaited(markRead(ref, e, read: false));
              Navigator.pop(context);
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'star' => _star(),
              'spam' => _act(EmailAct.spam),
              'forward' => _write(forward: true),
              _ => _load(fresh: true),
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'star',
                child: Text(e.starred ? 'Remove star' : 'Star'),
              ),
              const PopupMenuItem(value: 'forward', child: Text('Forward')),
              const PopupMenuItem(value: 'spam', child: Text('Report spam')),
              const PopupMenuItem(value: 'again', child: Text('Load again')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: o == null || _reading
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Row(
                  children: [
                    for (final (icon, label, all, forward) in const [
                      (Icons.reply, 'Reply', false, false),
                      (Icons.reply_all, 'Reply all', true, false),
                      (Icons.forward, 'Forward', false, true),
                    ]) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _write(all: all, forward: forward),
                          icon: Icon(icon, size: 18),
                          label: Text(label, maxLines: 1),
                        ),
                      ),
                      if (!forward) const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
            ),
      body: html != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _EmailHeader(email: e, message: first, onStar: _star),
                if (first!.attachments.isNotEmpty)
                  _Attachments(first.attachments),
                Expanded(child: EmailHtml(html, key: ValueKey(e.id))),
              ],
            )
          : ListView(
              padding: EdgeInsets.fromLTRB(
                readingInset(context, 0),
                0,
                readingInset(context, 0),
                24,
              ),
              children: [
                _EmailHeader(email: e, message: first, onStar: _star),
                if (_reading && _error == null)
                  const LinearProgressIndicator(minHeight: 2),
                if (o == null && _error == null) ...[
                  if (e.snippet.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        e.snippet,
                        style: TextStyle(color: context.nexus.muted),
                      ),
                    ),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Couldn\'t open it.\n\n$_error'),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _load,
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                if (o != null) ..._plain(context, o),
              ],
            ),
    );
  }

  /// A thread as text: what OpenAide read (or a mail without HTML).
  List<Widget> _plain(BuildContext context, OpenedEmail o) {
    final scheme = Theme.of(context).colorScheme;
    final muted = context.nexus.muted;
    return [
      if (o.summary.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Card(
            elevation: 0,
            color: scheme.primaryContainer.withValues(alpha: 0.4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.auto_awesome, size: 18, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(o.summary)),
                ],
              ),
            ),
          ),
        ),
      for (final (i, m) in o.messages.indexed) ...[
        if (i > 0) ...[const Divider(height: 24), _Sender(message: m)],
        if (m.attachments.isNotEmpty) _Attachments(m.attachments),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          // What OpenAide read comes back as Markdown, links and all.
          child: ref.read(mailSourceProvider).value == nexusMailSource
              ? MarkdownBlock(data: m.body, config: nexusMarkdown(context))
              : SelectableText(
                  m.body,
                  style: const TextStyle(fontSize: 15, height: 1.45),
                ),
        ),
      ],
      if (o.suggestedReply.isNotEmpty)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Card(
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
                  Text(
                    'OpenAide would reply',
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(color: muted),
                  ),
                  const SizedBox(height: 6),
                  Text(o.suggestedReply),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: () => _write(text: o.suggestedReply),
                      child: const Text('Use this reply'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ];
  }
}

/// The subject with its star, and who sent it.
class _EmailHeader extends StatelessWidget {
  const _EmailHeader({required this.email, this.message, required this.onStar});
  final Email email;
  final EmailMessage? message;
  final VoidCallback onStar;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                email.subject.isEmpty ? '(no subject)' : email.subject,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: email.starred ? 'Remove star' : 'Star',
              onPressed: onStar,
              icon: Icon(
                email.starred ? Icons.star : Icons.star_border,
                color: email.starred ? Colors.amber.shade700 : null,
              ),
            ),
          ],
        ),
      ),
      _Sender(
        message:
            message ??
            EmailMessage(from: email.from, to: email.to, date: email.date),
      ),
    ],
  );
}

/// Who sent a message, to whom, and when.
class _Sender extends StatelessWidget {
  const _Sender({required this.message});
  final EmailMessage message;

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final name = Email(id: '', from: message.from).fromName;
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase()),
      ),
      title: Text(
        name,
        style: const TextStyle(fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        message.to.isEmpty ? message.from : 'to ${message.to}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: muted),
      ),
      trailing: Text(
        _when(context, message.date),
        style: TextStyle(color: muted, fontSize: 12),
      ),
    );
  }
}

class _Attachments extends StatelessWidget {
  const _Attachments(this.names);
  final List<String> names;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final n in names)
          Chip(
            avatar: const Icon(Icons.attach_file, size: 16),
            label: Text(n, overflow: TextOverflow.ellipsis),
          ),
      ],
    ),
  );
}

class _SwipeBack extends StatelessWidget {
  const _SwipeBack({
    required this.icon,
    required this.label,
    required this.start,
  });
  final IconData icon;
  final String label;
  final bool start;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: start ? scheme.primaryContainer : scheme.errorContainer,
      alignment: start ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon), const SizedBox(width: 8), Text(label)],
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
  const ReplyEditor({
    super.key,
    this.replyTo,
    this.text = '',
    this.all = false,
    this.forward = false,
  });

  /// Null for a new email.
  final OpenedEmail? replyTo;
  final String text;

  /// Starts as a reply to everyone on it.
  final bool all;

  /// Sends [replyTo] on to someone, instead of answering it.
  final bool forward;

  @override
  ConsumerState<ReplyEditor> createState() => _ReplyEditorState();
}

class _ReplyEditorState extends ConsumerState<ReplyEditor> {
  late final _body = TextEditingController(text: widget.text);
  final _to = TextEditingController();
  final _subject = TextEditingController();
  late bool _all = widget.all;
  bool _sending = false;

  bool get _isReply => widget.replyTo != null && !widget.forward;
  bool get _isForward => widget.replyTo != null && widget.forward;

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
    if (_isForward) {
      if (_to.text.trim().isEmpty) {
        return _say(context, 'Add who it goes to');
      }
    } else if (text.isEmpty) {
      return _say(context, 'Write something first');
    }
    if (!_isReply &&
        !_isForward &&
        (_to.text.trim().isEmpty || _subject.text.trim().isEmpty)) {
      return _say(context, 'Add who it is to and a subject');
    }
    final o = widget.replyTo;
    final to = o == null || _isForward
        ? _to.text.trim()
        : (_all ? 'everyone on the thread' : o.email.from);
    final source = await ref.read(mailSourceProvider.future);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Send this email?'),
        content: Text(
          source == nexusMailSource
              ? 'OpenAide sends it from your Gmail to $to.'
              : 'Sent from $source to $to.',
        ),
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
      if (o != null && _isForward) {
        await agent.forward(o.email, to: _to.text.trim(), text: text);
      } else if (o != null) {
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
          title: Text(
            o == null
                ? 'New email'
                : _isForward
                ? 'Forward'
                : 'Reply',
          ),
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
            if (o != null && _isForward) ...[
              TextField(
                controller: _to,
                keyboardType: TextInputType.emailAddress,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'To'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Fwd: ${o.email.subject}',
                  style: TextStyle(color: context.nexus.muted),
                ),
              ),
            ] else if (o != null) ...[
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

/// "Email", with whose mail it is under it.
class _SourceTitle extends ConsumerWidget {
  const _SourceTitle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(mailSourceProvider).value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Email'),
        if (source != null)
          Text(
            source == nexusMailSource ? 'Through OpenAide' : source,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: context.nexus.muted),
          ),
      ],
    );
  }
}

/// Picks whose mail Email shows: each account on the phone, or Nexus when
/// signed in to a server; and adds accounts.
class _SourceMenu extends ConsumerWidget {
  const _SourceMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(mailAccountsProvider).value;
    final source = ref.watch(mailSourceProvider).value;
    final server = ref.watch(sessionProvider).value != null;
    return PopupMenuButton<String>(
      tooltip: 'Accounts',
      icon: const Icon(Icons.account_circle_outlined),
      onSelected: (v) {
        if (v == '+') {
          Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const AddMailAccount()),
          );
        } else {
          ref.read(mailAccountsProvider.notifier).show(v);
        }
      },
      itemBuilder: (_) => [
        if (server)
          CheckedPopupMenuItem(
            value: nexusMailSource,
            checked: source == nexusMailSource,
            child: const Text('Through OpenAide'),
          ),
        for (final a in accounts?.accounts ?? const <MailAccountConfig>[])
          CheckedPopupMenuItem(
            value: a.email,
            checked: source == a.email,
            child: Text(a.email),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: '+',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.add),
            title: Text('Add an email account'),
          ),
        ),
      ],
    );
  }
}

/// Through OpenAide every email waits for the AI; asks to connect the
/// mailbox itself, which opens mail at once and as its sender laid it out.
class _ConnectGmail extends StatelessWidget {
  const _ConnectGmail();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      elevation: 0,
      color: scheme.primaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Emails open slowly here because OpenAide reads each one '
              'first. Connect your Gmail for instant email that looks like '
              'Gmail.',
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const AddMailAccount(),
                  ),
                ),
                icon: const Icon(Icons.bolt, size: 18),
                label: const Text('Connect Gmail'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
