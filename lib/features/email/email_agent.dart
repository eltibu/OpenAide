/// Email through Nexus: the app doesn't sign in to Gmail itself. It asks
/// Nexus, in a chat of its own on the server, to read or send mail with
/// the Gmail access Nexus already has, and reads Nexus's answers (JSON)
/// into the Email screen. The chat is a normal one, so what Nexus did can
/// be looked at on the web too.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/models/chat.dart';

const _uuid = Uuid();

/// The chat the app talks email in, and the settings key that remembers it.
const emailChatTitle = 'Email (OpenAide app)';
const emailChatKey = 'nexusEmailChatId';

/// Chats the app works in on its own (Email), kept out of reply toasts.
final appWorkingChats = <String>{};

/// Where the email chat keeps the emails the app has seen.
const emailStoreKey = 'nexusEmails';

class Email {
  const Email({
    required this.id,
    this.thread = '',
    this.from = '',
    this.to = '',
    this.subject = '',
    this.date,
    this.snippet = '',
    this.unread = false,
    this.starred = false,
    this.note = '',
  });

  factory Email.fromJson(Map j) => Email(
    id: '${j['id'] ?? ''}',
    thread: '${j['thread'] ?? j['thread_id'] ?? j['threadId'] ?? ''}',
    from: '${j['from'] ?? ''}',
    to: '${j['to'] ?? ''}',
    subject: '${j['subject'] ?? ''}',
    date: DateTime.tryParse('${j['date'] ?? ''}')?.toLocal(),
    snippet: '${j['snippet'] ?? ''}',
    unread: j['unread'] == true,
    starred: j['starred'] == true,
    note: '${j['note'] ?? ''}',
  );

  Email copyWith({bool? unread, bool? starred}) => Email(
    id: id,
    thread: thread,
    from: from,
    to: to,
    subject: subject,
    date: date,
    snippet: snippet,
    unread: unread ?? this.unread,
    starred: starred ?? this.starred,
    note: note,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'thread': thread,
    'from': from,
    'to': to,
    'subject': subject,
    'date': date?.toUtc().toIso8601String(),
    'snippet': snippet,
    'unread': unread,
    'starred': starred,
    'note': note,
  };

  final String id;
  final String thread;
  final String from;
  final String to;
  final String subject;
  final DateTime? date;
  final String snippet;
  final bool unread;
  final bool starred;

  /// What Nexus says about it.
  final String note;

  /// The sender's name without the address.
  String get fromName {
    final m = RegExp(r'^\s*"?([^"<]+?)"?\s*<').firstMatch(from);
    return (m?.group(1) ?? from).trim();
  }
}

/// One message of a thread, opened.
class EmailMessage {
  const EmailMessage({
    this.from = '',
    this.to = '',
    this.date,
    this.body = '',
    this.html = '',
    this.attachments = const [],
  });

  factory EmailMessage.fromJson(Map j) => EmailMessage(
    from: '${j['from'] ?? ''}',
    to: '${j['to'] ?? ''}',
    date: DateTime.tryParse('${j['date'] ?? ''}')?.toLocal(),
    body: '${j['body'] ?? j['text'] ?? ''}',
    html: '${j['html'] ?? ''}',
    attachments: [for (final a in j['attachments'] as List? ?? const []) '$a'],
  );

  final String from;
  final String to;
  final DateTime? date;
  final String body;

  /// The email as its sender laid it out, when it has an HTML part.
  final String html;

  /// File names of what came with it.
  final List<String> attachments;

  Map<String, dynamic> toJson() => {
    'from': from,
    'to': to,
    'date': date?.toUtc().toIso8601String(),
    'body': body,
    if (html.isNotEmpty) 'html': html,
    if (attachments.isNotEmpty) 'attachments': attachments,
  };
}

/// An email opened: the thread (oldest first), Nexus's summary and the
/// reply it would send.
class OpenedEmail {
  const OpenedEmail({
    required this.email,
    required this.messages,
    this.summary = '',
    this.suggestedReply = '',
  });

  factory OpenedEmail.fromJson(Map j) => OpenedEmail(
    email: Email.fromJson(j['email'] as Map? ?? const {}),
    messages: [
      for (final m in (j['messages'] as List? ?? const []).whereType<Map>())
        EmailMessage.fromJson(m),
    ],
    summary: '${j['summary'] ?? ''}',
    suggestedReply: '${j['suggested_reply'] ?? ''}',
  );

  final Email email;
  final List<EmailMessage> messages;
  final String summary;
  final String suggestedReply;

  Map<String, dynamic> toJson() => {
    'email': email.toJson(),
    'messages': [for (final m in messages) m.toJson()],
    'summary': summary,
    'suggested_reply': suggestedReply,
  };
}

/// What Nexus just listed, added to what was kept: new ones and updates
/// replace the kept copy, nothing kept is dropped because a check missed
/// it, newest first, at most [max].
List<Email> mergeEmails(List<Email> fresh, List<Email> kept, {int max = 300}) {
  final byId = <String, Email>{
    for (final e in kept) e.id: e,
    for (final e in fresh) e.id: e,
  };
  final all = byId.values.toList()
    ..sort((a, b) {
      final ad = a.date, bd = b.date;
      if (ad == null && bd == null) return 0;
      if (ad == null) return 1;
      if (bd == null) return -1;
      return bd.compareTo(ad);
    });
  return all.length > max ? all.sublist(0, max) : all;
}

/// [emails] with what was marked read or unread in the app (`read` in
/// the store: id to true for read) over what Gmail said.
List<Email> withReadState(List<Email> emails, Map read) => [
  for (final e in emails)
    read[e.id] is bool ? e.copyWith(unread: read[e.id] != true) : e,
];

/// The emails kept for [folder] in [store], newest first, with the read
/// state from the app.
List<Email> keptIn(Map store, String folder) => withReadState([
  for (final e in (store[folder] as List? ?? const []).whereType<Map>())
    Email.fromJson(e),
], store['read'] as Map? ?? const {});

/// When Nexus last checked [folder], as kept in [store].
DateTime? checkedIn(Map store, String folder) {
  final checked = store['checked'];
  return checked is Map
      ? DateTime.tryParse('${checked[folder] ?? ''}')?.toLocal()
      : null;
}

/// How long a check stays fresh: opening Email again within it shows the
/// kept list without asking Nexus (pulling down still checks).
const checkEvery = Duration(minutes: 15);

bool needsCheck(DateTime? checked, {DateTime? now}) =>
    checked == null || (now ?? DateTime.now()).difference(checked) > checkEvery;

/// The server's store with the phone's copy: the server's is the real one,
/// but what the phone changed while the server couldn't be reached
/// (`synced` false) is kept on top of it.
Map<String, dynamic> mergeStores(Map server, Map local) {
  final out = Map<String, dynamic>.from(server);
  if (local['synced'] != false) return out..remove('synced');
  for (final folder in ['inbox', 'sent']) {
    final merged = mergeEmails(
      [
        for (final e in (local[folder] as List? ?? const []).whereType<Map>())
          Email.fromJson(e),
      ],
      [
        for (final e in (server[folder] as List? ?? const []).whereType<Map>())
          Email.fromJson(e),
      ],
    );
    if (merged.isNotEmpty) out[folder] = [for (final e in merged) e.toJson()];
  }
  out['read'] = {...?server['read'] as Map?, ...?local['read'] as Map?};
  out['checked'] = {
    ...?server['checked'] as Map?,
    ...?local['checked'] as Map?,
  };
  return out..remove('synced');
}

/// Drops read marks for emails no longer kept, so the store stays small.
Map<String, dynamic> pruneRead(Map<String, dynamic> store) {
  final ids = {
    for (final folder in ['inbox', 'sent'])
      for (final e in (store[folder] as List? ?? const []).whereType<Map>())
        '${e['id']}',
  };
  final read = store['read'];
  if (read is Map) {
    store['read'] = {
      for (final e in read.entries)
        if (ids.contains('${e.key}')) '${e.key}': e.value,
    };
  }
  return store;
}

/// The phone's copy of the kept lists, read marks and check times, so
/// Email shows at once when opened, before anything is fetched. The copy
/// on the server is the real one; opened emails stay there only.
class EmailCache {
  const EmailCache();
  static const _key = 'nexusEmailCache';
  static const _storage = FlutterSecureStorage();

  Future<Map<String, dynamic>> read() async {
    try {
      final text = await _storage.read(key: _key);
      final j = text == null ? null : jsonDecode(text);
      return j is Map ? j.cast<String, dynamic>() : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> write(Map<String, dynamic> store, {required bool synced}) async {
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode({
          for (final e in store.entries)
            if (e.key != 'opened') e.key: e.value,
          'synced': synced,
        }),
      );
    } catch (_) {
      // Only a copy: the server still has the lists.
    }
  }
}

/// The JSON in a model's answer, with any words or fences around it
/// left out.
Object? answerJson(String text) {
  final t = text.trim();
  final starts = [t.indexOf('['), t.indexOf('{')].where((i) => i >= 0);
  if (starts.isEmpty) return null;
  final start = starts.reduce((a, b) => a < b ? a : b);
  final close = t[start] == '[' ? ']' : '}';
  final end = t.lastIndexOf(close);
  if (end <= start) return null;
  try {
    return jsonDecode(t.substring(start, end + 1));
  } on FormatException {
    return null;
  }
}

class EmailAgentError implements Exception {
  const EmailAgentError(this.message);
  final String message;
  @override
  String toString() => message;
}

const _rules =
    'You are helping the OpenAide app show my email. Use your Gmail access '
    '(the same tools you use when I ask you about email in chat). Answer '
    'with the JSON asked for and nothing else: no words before or after it, '
    'no code fence. If you can\'t reach Gmail, answer {"error": "what went '
    'wrong"}.';

String listRequest({
  required String folder,
  int count = 25,
  String query = '',
}) =>
    'Get the $count most recent emails in my Gmail '
    '${folder == 'sent' ? 'Sent folder' : 'inbox'}'
    '${query.trim().isEmpty ? '' : ' that match: ${query.trim()}'}. '
    'Answer with a JSON array, newest first, one object per email: '
    '{"id": the Gmail message id, "thread": the thread id, "from": "Name '
    '<address>", "to": "Name <address>", "subject": "...", "date": ISO 8601 '
    'date and time, "snippet": the first line or two, "unread": true or '
    'false, "note": one short sentence from you on what it is and whether '
    'I need to do anything}.';

String openRequest(Email e) =>
    'Open the email with Gmail message id ${e.id}'
    '${e.thread.isEmpty ? '' : ' (thread ${e.thread})'}, subject '
    '"${e.subject}". Answer with a JSON object: {"messages": every message '
    'of its thread, oldest first, each {"from", "to", "date": ISO 8601, '
    '"body": the full text as plain text}, "summary": two or three '
    'sentences on what it is about and what is asked of me, '
    '"suggested_reply": the reply you would send for me, or "" if it needs '
    'none}.';

String sendRequest(Email e, String text, {bool all = false}) =>
    'Send this reply now, as me, in the same thread as the email with Gmail '
    'message id ${e.id}${e.thread.isEmpty ? '' : ' (thread ${e.thread})'}, '
    'to ${all ? 'everyone on it' : 'its sender'}. Send exactly this text, '
    'unchanged:\n<<<\n$text\n>>>\nAnswer with a JSON object: {"sent": true '
    'or false, "error": "" or what went wrong}.';

String composeRequest({
  required String to,
  required String subject,
  required String text,
}) =>
    'Send a new email now, as me, to $to with the subject "$subject". Send '
    'exactly this text, unchanged:\n<<<\n$text\n>>>\nAnswer with a JSON '
    'object: {"sent": true or false, "error": "" or what went wrong}.';

/// Where the Email screen's mail comes from: Nexus on the server
/// ([EmailAgent]) or an account the app signs in to itself (DirectMail).
abstract interface class MailSource {
  /// Who the mail is shown and sent as ("Nexus" or an address).
  String get label;

  /// Nexus writes a note on each email and a summary when one is opened.
  bool get hasNotes;

  /// The phone's copy of the lists, shown before anything is fetched.
  Future<Map<String, dynamic>> phoneCopy();

  Future<List<Email>> kept(String folder);
  Future<DateTime?> checkedAt(String folder);
  Future<Map> readMarks();
  Future<OpenedEmail?> keptOpen(Email e);
  Future<void> setRead(Email e, {bool read = true});
  Future<List<Email>> check(String folder);
  Future<OpenedEmail> openAndKeep(Email e);
  Future<List<Email>> list({String folder = 'inbox', String query = ''});
  Future<void> reply(Email e, String text, {bool all = false});
  Future<void> compose({
    required String to,
    required String subject,
    required String text,
  });

  /// Sends [e] on to [to], with [text] above it.
  Future<void> forward(Email e, {required String to, String text = ''});

  /// Out of the inbox, still kept in the account.
  Future<void> archive(Email e);

  /// To the trash.
  Future<void> trash(Email e);

  /// To spam.
  Future<void> spam(Email e);

  Future<void> setStarred(Email e, bool starred);
}

/// [store] without [id] in any folder, after it was archived or deleted.
void dropEmail(Map<String, dynamic> store, String id) {
  for (final folder in ['inbox', 'sent']) {
    final list = store[folder];
    if (list is List) {
      store[folder] = [
        for (final j in list.whereType<Map>())
          if (j['id'] != id) j,
      ];
    }
  }
  final opened = store['opened'];
  if (opened is Map) opened.remove(id);
}

/// [store] with [id] starred or not in every folder.
void starEmail(Map<String, dynamic> store, String id, bool starred) {
  for (final folder in ['inbox', 'sent']) {
    final list = store[folder];
    if (list is List) {
      store[folder] = [
        for (final j in list.whereType<Map>())
          j['id'] == id ? {...j, 'starred': starred} : j,
      ];
    }
  }
}

String forwardRequest(Email e, {required String to, String text = ''}) =>
    'Forward the email with Gmail message id ${e.id}, subject '
    '"${e.subject}", now, as me, to $to'
    '${text.trim().isEmpty ? '' : ', with exactly this text above it, unchanged:\n<<<\n$text\n>>>\n'}'
    '. Keep its attachments. Answer with a JSON object: {"sent": true or '
    'false, "error": "" or what went wrong}.';

String actRequest(Email e, String what) =>
    'For the email with Gmail message id ${e.id}, subject "${e.subject}": '
    '$what. Answer with a JSON object: {"done": true or false, "error": "" '
    'or what went wrong}.';

/// Runs requests as turns in the email chat and waits for the answers.
class EmailAgent implements MailSource {
  EmailAgent(
    this.client, {
    required this.model,
    required this.options,
    this.cache = const EmailCache(),
  });

  final OpenWebUiClient client;
  final String model;

  /// What a chat with [model] sends (its tools, features...), so Nexus
  /// works here as it does in any chat.
  final Map<String, dynamic> options;

  final EmailCache cache;

  @override
  String get label => 'OpenAide';

  @override
  bool get hasNotes => true;

  @override
  Future<Map<String, dynamic>> phoneCopy() => cache.read();

  String? _chatId;

  Future<String?> _savedChatId() async {
    try {
      final ui = (await client.userSettings())['ui'];
      final id = ui is Map ? ui[emailChatKey] : null;
      if (id is! String || id.isEmpty) return null;
      appWorkingChats.add(id);
      return id;
    } catch (_) {
      return null;
    }
  }

  /// Emails kept on the server, in the email chat (`nexusEmails`): each
  /// folder's list, the emails already opened, which ones were read in the
  /// app and when each folder was last checked, so nothing disappears
  /// between checks, an opened email shows at once and read stays read on
  /// every phone.
  Map<String, dynamic>? _kept;
  Future<Map<String, dynamic>>? _loading;

  /// [_kept] is only the phone's copy: the server couldn't be read yet.
  bool _fromPhone = false;

  Future<Map<String, dynamic>> _store() async {
    if (_kept != null) return _kept!;
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  /// The store on the server, or null when it can't be read now.
  Future<Map<String, dynamic>?> _serverStore() async {
    _chatId ??= await _savedChatId();
    if (_chatId == null) return {};
    try {
      final saved = (await client.chat(_chatId!)).extra[emailStoreKey];
      return saved is Map ? saved.cast<String, dynamic>() : {};
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _load() async {
    final local = await cache.read();
    final server = await _serverStore();
    if (server == null) {
      _fromPhone = true;
      return _kept = Map<String, dynamic>.of(local)..remove('synced');
    }
    _kept = mergeStores(server, local);
    if (local['synced'] == false) {
      await _save((_) {});
    } else {
      unawaited(cache.write(_kept!, synced: true));
    }
    return _kept!;
  }

  /// The emails kept for [folder], newest first.
  @override
  Future<List<Email>> kept(String folder) async =>
      keptIn(await _store(), folder);

  /// When Nexus last checked [folder].
  @override
  Future<DateTime?> checkedAt(String folder) async =>
      checkedIn(await _store(), folder);

  /// What was marked read or unread in the app, by email id.
  @override
  Future<Map> readMarks() async => (await _store())['read'] as Map? ?? {};

  /// An email opened before, as Nexus showed it then.
  @override
  Future<OpenedEmail?> keptOpen(Email e) async {
    final opened = (await _store())['opened'];
    final j = opened is Map ? opened[e.id] : null;
    return j is Map ? OpenedEmail.fromJson(j) : null;
  }

  Future<void> _save(void Function(Map<String, dynamic> store) change) async {
    var store = await _store();
    if (_fromPhone) {
      // Never write the phone's copy over what only the server has (the
      // opened emails): read the server's first and put the changes on it.
      final server = await _serverStore();
      if (server != null) {
        _fromPhone = false;
        store = _kept = mergeStores(server, {...store, 'synced': false});
      }
    }
    change(store);
    pruneRead(store);
    final id = _chatId;
    var synced = false;
    if (id != null && !_fromPhone) {
      try {
        await client.send(
          'POST',
          '/api/v1/chats/$id',
          body: {
            'chat': {emailStoreKey: store},
          },
        );
        synced = true;
      } catch (_) {
        // Kept on the phone until the next save gets through.
      }
    }
    await cache.write(store, synced: synced);
  }

  /// Marks [e] read (or unread again) in the app, kept on the server.
  @override
  Future<void> setRead(Email e, {bool read = true}) => _save((s) {
    s['read'] = {...?s['read'] as Map?, e.id: read};
  });

  /// Checks [folder] with Nexus and keeps the result with what was there.
  @override
  Future<List<Email>> check(String folder) async {
    final fresh = await list(folder: folder);
    await _save((s) {
      final merged = mergeEmails(fresh, [
        for (final e in (s[folder] as List? ?? const []).whereType<Map>())
          Email.fromJson(e),
      ]);
      s[folder] = [for (final e in merged) e.toJson()];
      s['checked'] = {
        ...?s['checked'] as Map?,
        folder: DateTime.now().toUtc().toIso8601String(),
      };
    });
    return keptIn(await _store(), folder);
  }

  /// Opens [e] with Nexus and keeps what it showed.
  @override
  Future<OpenedEmail> openAndKeep(Email e) async {
    final opened = await open(e);
    await _save((s) {
      final all = Map<String, dynamic>.from(s['opened'] as Map? ?? const {});
      all.remove(e.id);
      all[e.id] = opened.toJson();
      // The 100 opened last.
      while (all.length > 100) {
        all.remove(all.keys.first);
      }
      s['opened'] = all;
    });
    return opened;
  }

  /// Asks Nexus and returns its whole answer once it is done.
  Future<String> ask(
    String request, {
    Duration timeout = const Duration(minutes: 4),
  }) async {
    _chatId ??= await _savedChatId();
    Chat? chat;
    if (_chatId != null) {
      try {
        chat = await client.chat(_chatId!);
      } catch (_) {
        _chatId = null; // Deleted on the web: a new one is made.
      }
    }
    final user = ChatMessage(
      id: _uuid.v4(),
      role: 'user',
      content: request,
      parentId: chat?.currentId,
    );
    final replyId = _uuid.v4();
    final turn = await client.startTurn(
      model: model,
      chatId: _chatId,
      userMessage: user,
      replyId: replyId,
      // Only this request goes to the model, not the chat's history.
      messages: [
        {'role': 'system', 'content': _rules},
        {'role': 'user', 'content': request},
      ],
      sessionId: 'nexus-app-email-${_uuid.v4()}',
      options: {...options, 'background_tasks': const {}},
    );
    if (_chatId != turn.chatId) {
      _chatId = turn.chatId;
      unawaited(_remember(turn.chatId));
    }
    final until = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final ChatMessage? reply;
      try {
        reply = (await client.chat(turn.chatId)).messages[replyId];
      } catch (_) {
        continue; // The answer keeps going on the server.
      }
      if (reply == null) continue;
      if (reply.error != null) throw EmailAgentError(reply.error!);
      if (reply.done) return reply.content;
    }
    throw const EmailAgentError('OpenAide took too long to answer. Try again.');
  }

  Future<void> _remember(String id) async {
    appWorkingChats.add(id);
    try {
      await client.renameChat(id, emailChatTitle);
      await client.send(
        'POST',
        '/api/v1/users/user/settings/update',
        body: {
          'ui': {emailChatKey: id},
        },
      );
    } catch (_) {
      // Found again by its id next time it is kept; a new one otherwise.
    }
  }

  Future<Object?> _askJson(String request) async {
    final text = await ask(request);
    final json = answerJson(text);
    if (json is Map &&
        json['error'] is String &&
        '${json['error']}'.isNotEmpty) {
      if (!json.containsKey('sent')) throw EmailAgentError('${json['error']}');
    }
    if (json == null) {
      throw EmailAgentError(
        "OpenAide's answer wasn't the email list the app needs. Try again, "
        'and check that its model can use your email tool.',
      );
    }
    return json;
  }

  @override
  Future<List<Email>> list({String folder = 'inbox', String query = ''}) async {
    final json = await _askJson(listRequest(folder: folder, query: query));
    final items = json is List
        ? json
        : json is Map && json['emails'] is List
        ? json['emails'] as List
        : const [];
    return [
      for (final e in items.whereType<Map>())
        if ('${e['id'] ?? ''}'.isNotEmpty) Email.fromJson(e),
    ];
  }

  Future<OpenedEmail> open(Email e) async {
    final json = await _askJson(openRequest(e));
    final j = json is Map ? json : const {};
    final messages = [
      for (final m in (j['messages'] as List? ?? const []).whereType<Map>())
        EmailMessage.fromJson(m),
    ];
    return OpenedEmail(
      email: e,
      messages: messages.isEmpty
          ? [
              EmailMessage(
                from: e.from,
                to: e.to,
                date: e.date,
                body: '${j['body'] ?? e.snippet}',
              ),
            ]
          : messages,
      summary: '${j['summary'] ?? ''}',
      suggestedReply: '${j['suggested_reply'] ?? ''}',
    );
  }

  /// Sends; throws with Nexus's reason when it didn't.
  @override
  Future<void> reply(Email e, String text, {bool all = false}) async =>
      _sent(await _askJson(sendRequest(e, text, all: all)));

  @override
  Future<void> compose({
    required String to,
    required String subject,
    required String text,
  }) async => _sent(
    await _askJson(composeRequest(to: to, subject: subject, text: text)),
  );

  @override
  Future<void> forward(Email e, {required String to, String text = ''}) async =>
      _sent(await _askJson(forwardRequest(e, to: to, text: text)));

  Future<void> _act(Email e, String what) async {
    final json = await _askJson(actRequest(e, what));
    if (json is Map && json['done'] == true) return;
    final why = json is Map ? '${json['error'] ?? ''}' : '';
    throw EmailAgentError(why.isEmpty ? 'It wasn\'t done.' : why);
  }

  @override
  Future<void> archive(Email e) async {
    await _act(e, 'Archive it (remove it from the inbox, keep it in All Mail)');
    await _save((s) => dropEmail(s, e.id));
  }

  @override
  Future<void> trash(Email e) async {
    await _act(e, 'Move it to the trash');
    await _save((s) => dropEmail(s, e.id));
  }

  @override
  Future<void> spam(Email e) async {
    await _act(e, 'Mark it as spam');
    await _save((s) => dropEmail(s, e.id));
  }

  @override
  Future<void> setStarred(Email e, bool starred) async {
    await _act(e, starred ? 'Star it' : 'Remove its star');
    await _save((s) => starEmail(s, e.id, starred));
  }

  void _sent(Object? json) {
    if (json is Map && json['sent'] == true) return;
    final why = json is Map ? '${json['error'] ?? ''}' : '';
    throw EmailAgentError(
      why.isEmpty ? 'OpenAide didn\'t say it was sent. Check Sent.' : why,
    );
  }
}
