/// Email through Nexus: the app doesn't sign in to Gmail itself. It asks
/// Nexus, in a chat of its own on the server, to read or send mail with
/// the Gmail access Nexus already has, and reads Nexus's answers (JSON)
/// into the Email screen. The chat is a normal one, so what Nexus did can
/// be looked at on the web too.
library;

import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/models/chat.dart';

const _uuid = Uuid();

/// The chat the app talks email in, and the settings key that remembers it.
const emailChatTitle = 'Email (Nexus app)';
const emailChatKey = 'nexusEmailChatId';

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
    note: '${j['note'] ?? ''}',
  );

  final String id;
  final String thread;
  final String from;
  final String to;
  final String subject;
  final DateTime? date;
  final String snippet;
  final bool unread;

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
  const EmailMessage({this.from = '', this.to = '', this.date, this.body = ''});

  factory EmailMessage.fromJson(Map j) => EmailMessage(
    from: '${j['from'] ?? ''}',
    to: '${j['to'] ?? ''}',
    date: DateTime.tryParse('${j['date'] ?? ''}')?.toLocal(),
    body: '${j['body'] ?? j['text'] ?? ''}',
  );

  final String from;
  final String to;
  final DateTime? date;
  final String body;
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

  final Email email;
  final List<EmailMessage> messages;
  final String summary;
  final String suggestedReply;
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
    'You are helping the Nexus app show my email. Use your Gmail access '
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

/// Runs requests as turns in the email chat and waits for the answers.
class EmailAgent {
  EmailAgent(this.client, {required this.model, required this.options});

  final OpenWebUiClient client;
  final String model;

  /// What a chat with [model] sends (its tools, features...), so Nexus
  /// works here as it does in any chat.
  final Map<String, dynamic> options;

  String? _chatId;

  Future<String?> _savedChatId() async {
    try {
      final ui = (await client.userSettings())['ui'];
      final id = ui is Map ? ui[emailChatKey] : null;
      return id is String && id.isNotEmpty ? id : null;
    } catch (_) {
      return null;
    }
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
    throw const EmailAgentError('Nexus took too long to answer. Try again.');
  }

  Future<void> _remember(String id) async {
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
        'Nexus answered in words instead of the list the app needs:\n\n'
        '${text.length > 400 ? '${text.substring(0, 400)}…' : text}',
      );
    }
    return json;
  }

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
  Future<void> reply(Email e, String text, {bool all = false}) async =>
      _sent(await _askJson(sendRequest(e, text, all: all)));

  Future<void> compose({
    required String to,
    required String subject,
    required String text,
  }) async => _sent(
    await _askJson(composeRequest(to: to, subject: subject, text: text)),
  );

  void _sent(Object? json) {
    if (json is Map && json['sent'] == true) return;
    final why = json is Map ? '${json['error'] ?? ''}' : '';
    throw EmailAgentError(
      why.isEmpty ? 'Nexus didn\'t say it was sent. Check Sent.' : why,
    );
  }
}
