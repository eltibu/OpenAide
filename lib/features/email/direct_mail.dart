/// Email the app reads and sends itself, over IMAP and SMTP, for an
/// account added in Settings > Accounts. Works with no Open WebUI server:
/// the mail service is the server, and the phone keeps a copy of the lists
/// so Email opens at once.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:enough_mail/enough_mail.dart' as mail;
import 'package:path_provider/path_provider.dart';

import '../accounts/mail_accounts.dart';
import 'email_agent.dart';

/// Messages up to this size come down whole with the list, so opening one
/// needs no wait; bigger ones are fetched when opened.
const _wholeUpTo = 200 * 1024;

/// The phone's copy of an account's mail: lists, check times and the
/// emails opened, in the app's own files (not shared with other apps).
class DirectMailStore {
  DirectMailStore(this.email, {this.folder});
  final String email;

  /// Where the copies go; the app's support folder unless given.
  final Directory? folder;

  Future<File> _file() async {
    final dir = Directory(
      '${(folder ?? await getApplicationSupportDirectory()).path}/mail',
    );
    await dir.create(recursive: true);
    final name = sha1.convert(utf8.encode(email.toLowerCase())).toString();
    return File('${dir.path}/$name.json');
  }

  Future<Map<String, dynamic>> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      final j = jsonDecode(await f.readAsString());
      return j is Map ? j.cast<String, dynamic>() : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> write(Map<String, dynamic> store) async {
    try {
      final f = await _file();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(store));
      await tmp.rename(f.path);
    } catch (_) {
      // Only a copy: the mail service still has everything.
    }
  }

  Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// Plain text from an HTML email, for reading on a phone.
String htmlToText(String html) {
  var t = html
      .replaceAll(
        RegExp(
          r'<(style|script|head)[^>]*>.*?</\1>',
          caseSensitive: false,
          dotAll: true,
        ),
        '',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(r'</(p|div|tr|li|h[1-6]|blockquote)>', caseSensitive: false),
        '\n',
      )
      .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '• ')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  const entities = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&zwnj;': '',
    '&rsquo;': '’',
    '&lsquo;': '‘',
    '&rdquo;': '”',
    '&ldquo;': '“',
    '&hellip;': '…',
    '&mdash;': '—',
    '&ndash;': '–',
  };
  for (final e in entities.entries) {
    t = t.replaceAll(e.key, e.value);
  }
  t = t.replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m[2]!, radix: m[1]!.isEmpty ? 10 : 16);
    return code == null ? m[0]! : String.fromCharCode(code);
  });
  return t
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t ]+'), ' ').trim())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// The readable text of [m]: its plain part, or its HTML part as text.
String bodyText(mail.MimeMessage m) {
  final plain = m.decodeTextPlainPart()?.replaceAll('\r\n', '\n').trim();
  if (plain != null && plain.isNotEmpty) return plain;
  final html = m.decodeTextHtmlPart();
  return html == null ? '' : htmlToText(html.replaceAll('\r\n', '\n'));
}

String _address(mail.MailAddress a) => (a.personalName ?? '').trim().isEmpty
    ? a.email
    : '${a.personalName!.trim()} <${a.email}>';

String _addresses(List<mail.MailAddress>? list) =>
    (list ?? const []).map(_address).join(', ');

/// The email ids this app gives mail it reads itself: the folder and the
/// message's IMAP UID.
String directId(String folder, int uid) => '$folder:$uid';

(String, int)? parseDirectId(String id) {
  final i = id.lastIndexOf(':');
  if (i <= 0) return null;
  final uid = int.tryParse(id.substring(i + 1));
  return uid == null ? null : (id.substring(0, i), uid);
}

/// [m] as the Email screen shows it in a list.
Email emailFrom(mail.MimeMessage m, String folder) {
  final snippet = bodyText(m).replaceAll(RegExp(r'\s+'), ' ').trim();
  return Email(
    id: directId(folder, m.uid ?? 0),
    thread: m.getHeaderValue('message-id') ?? '',
    from: _addresses(m.from),
    to: _addresses(m.to),
    subject: m.decodeSubject() ?? '',
    date: m.decodeDate()?.toLocal(),
    snippet: snippet.length > 160 ? '${snippet.substring(0, 160)}…' : snippet,
    unread: !m.isSeen,
    starred: m.isFlagged,
  );
}

/// The HTML of [m] with its inline pictures (`cid:`) put in, so it shows
/// whole without fetching anything else.
String htmlOf(mail.MimeMessage m) {
  final html = m.decodeTextHtmlPart();
  if (html == null || html.trim().isEmpty) return '';
  return html.replaceAllMapped(RegExp(r'''cid:([^"'\s>)]+)'''), (x) {
    try {
      final part = m.getPartWithContentId(x[1]!);
      final bytes = part?.decodeContentBinary();
      if (part == null || bytes == null) return x[0]!;
      final type = part.mediaType.text;
      return 'data:$type;base64,${base64Encode(bytes)}';
    } catch (_) {
      return x[0]!;
    }
  });
}

/// The names of the files that came with [m].
List<String> attachmentNames(mail.MimeMessage m) {
  try {
    return [
      for (final info in m.findContentInfo(
        disposition: mail.ContentDisposition.attachment,
      ))
        info.fileName ?? 'attachment',
    ];
  } catch (_) {
    return const [];
  }
}

/// Each address in `a@b.com, Name <c@d.com>`.
List<mail.MailAddress> parseAddresses(String text) => [
  for (final part in text.split(RegExp(r'[,;]')))
    if (part.trim().isNotEmpty) mail.MailAddress.parse(part.trim()),
];

/// An account's mail, read and sent by the app itself.
class DirectMail implements MailSource {
  DirectMail(this.account, {DirectMailStore? store})
    : _store = store ?? DirectMailStore(account.email);

  final MailAccountConfig account;
  final DirectMailStore _store;
  Map<String, dynamic>? _kept;

  @override
  String get label => account.email;

  @override
  bool get hasNotes => false;

  @override
  Future<Map<String, dynamic>> phoneCopy() => _store.read();

  Future<Map<String, dynamic>> _load() async => _kept ??= await _store.read();

  Future<void> _save(void Function(Map<String, dynamic> s) change) async {
    final s = await _load();
    change(s);
    await _store.write(s);
  }

  /// Signs in, runs [work], and signs out again: a phone drops idle
  /// connections, so none is kept open between uses.
  Future<T> _session<T>(
    Future<T> Function(mail.MailClient c) work, {
    int wholeUpTo = _wholeUpTo,
  }) async {
    final mail.MailClient c;
    try {
      c = mail.MailClient(
        await account.toMailAccount(),
        downloadSizeLimit: wholeUpTo,
      );
    } catch (e) {
      throw EmailAgentError('Couldn\'t sign in to ${account.email}: $e');
    }
    try {
      await c.connect(timeout: const Duration(seconds: 25));
      return await work(c);
    } on mail.MailException catch (e) {
      throw EmailAgentError(
        'Couldn\'t reach ${account.email}: ${e.message ?? e}',
      );
    } finally {
      try {
        await c.disconnect();
      } catch (_) {}
    }
  }

  Future<mail.Mailbox> _select(mail.MailClient c, String folder) async {
    if (folder != 'sent') return c.selectInbox();
    final box = await _sentBox(c);
    if (box == null) {
      throw const EmailAgentError('This account has no Sent folder.');
    }
    return c.selectMailbox(box);
  }

  /// The Sent folder: the one marked as such, or by its usual names.
  Future<mail.Mailbox?> _sentBox(mail.MailClient c) => _box(
    c,
    [mail.MailboxFlag.sent],
    const ['sent', 'sent items', 'sent messages', 'sent mail'],
  );

  /// The first folder with one of [flags], else one with a usual [name].
  Future<mail.Mailbox?> _box(
    mail.MailClient c,
    List<mail.MailboxFlag> flags,
    List<String> names,
  ) async {
    final boxes = await c.listMailboxes();
    for (final f in flags) {
      final box = boxes.where((b) => b.hasFlag(f)).firstOrNull;
      if (box != null) return box;
    }
    return boxes.where((b) => names.contains(b.name.toLowerCase())).firstOrNull;
  }

  /// Moves [e] to the folder found by [flags] or [names], and drops it
  /// from the lists kept on the phone.
  Future<void> _move(
    Email e,
    List<mail.MailboxFlag> flags,
    List<String> names,
    String missing,
  ) async {
    final at = parseDirectId(e.id);
    if (at == null) throw const EmailAgentError('This email has no id.');
    await _session((c) async {
      final target = await _box(c, flags, names);
      if (target == null) throw EmailAgentError(missing);
      await _select(c, at.$1);
      await c.moveMessages(
        mail.MessageSequence.fromId(at.$2, isUid: true),
        target,
      );
    });
    await _save((s) => dropEmail(s, e.id));
  }

  /// Gmail archives by taking the Inbox label off, which IMAP does by
  /// moving to All Mail; others have an Archive folder.
  @override
  Future<void> archive(Email e) => _move(
    e,
    [mail.MailboxFlag.archive, mail.MailboxFlag.all],
    const ['archive', 'archives'],
    'This account has no Archive folder.',
  );

  @override
  Future<void> trash(Email e) => _move(
    e,
    [mail.MailboxFlag.trash],
    const ['trash', 'deleted items', 'deleted messages', 'bin'],
    'This account has no Trash folder.',
  );

  @override
  Future<void> spam(Email e) => _move(
    e,
    [mail.MailboxFlag.junk],
    const ['spam', 'junk', 'junk e-mail', 'junk email', 'bulk mail'],
    'This account has no Spam folder.',
  );

  @override
  Future<void> setStarred(Email e, bool starred) async {
    await _save((s) => starEmail(s, e.id, starred));
    final at = parseDirectId(e.id);
    if (at == null) return;
    await _session((c) async {
      await _select(c, at.$1);
      final seq = mail.MessageSequence.fromId(at.$2, isUid: true);
      starred ? await c.markFlagged(seq) : await c.markUnflagged(seq);
    });
  }

  @override
  Future<void> forward(Email e, {required String to, String text = ''}) {
    final List<mail.MailAddress> recipients;
    try {
      recipients = parseAddresses(to);
    } on FormatException {
      throw EmailAgentError('"$to" isn\'t an email address.');
    }
    if (recipients.isEmpty) throw const EmailAgentError('Who is it to?');
    return _session((c) async {
      final original = await _fetch(c, e.id);
      final b =
          mail.MessageBuilder.prepareForwardMessage(
              original,
              from: _from,
              quoteMessage: false,
            )
            ..to = recipients
            ..text = [
              if (text.trim().isNotEmpty) '${text.trim()}\n',
              '---------- Forwarded message ----------',
              'From: ${_addresses(original.from)}',
              if (original.decodeDate() != null)
                'Date: ${original.decodeDate()!.toLocal()}',
              'Subject: ${original.decodeSubject() ?? ''}',
              'To: ${_addresses(original.to)}',
              '',
              bodyText(original),
            ].join('\n');
      await _send(c, b);
    });
  }

  @override
  Future<List<Email>> kept(String folder) async =>
      keptIn(await _load(), folder);

  @override
  Future<DateTime?> checkedAt(String folder) async =>
      checkedIn(await _load(), folder);

  /// Read or not comes from the mail service itself, not from marks kept
  /// by the app.
  @override
  Future<Map> readMarks() async => const {};

  @override
  Future<OpenedEmail?> keptOpen(Email e) async {
    final opened = (await _load())['opened'];
    final j = opened is Map ? opened[e.id] : null;
    return j is Map ? OpenedEmail.fromJson(j) : null;
  }

  void _keepOpened(Map<String, dynamic> s, OpenedEmail o) {
    final all = Map<String, dynamic>.from(s['opened'] as Map? ?? const {});
    all.remove(o.email.id);
    all[o.email.id] = o.toJson();
    while (all.length > 100) {
      all.remove(all.keys.first);
    }
    s['opened'] = all;
  }

  OpenedEmail _opened(Email e, mail.MimeMessage m) => OpenedEmail(
    email: e,
    messages: [
      EmailMessage(
        from: _addresses(m.from),
        to: _addresses([...?m.to, ...?m.cc]),
        date: m.decodeDate()?.toLocal(),
        body: bodyText(m),
        html: htmlOf(m),
        attachments: attachmentNames(m),
      ),
    ],
  );

  /// Marks it read or unread with the mail service, so it shows the same
  /// in every mail app.
  @override
  Future<void> setRead(Email e, {bool read = true}) async {
    await _save((s) {
      for (final folder in ['inbox', 'sent']) {
        final list = s[folder];
        if (list is! List) continue;
        s[folder] = [
          for (final j in list.whereType<Map>())
            j['id'] == e.id ? {...j, 'unread': !read} : j,
        ];
      }
    });
    final at = parseDirectId(e.id);
    if (at == null) return;
    await _session((c) async {
      await _select(c, at.$1);
      final seq = mail.MessageSequence.fromId(at.$2, isUid: true);
      read ? await c.markSeen(seq) : await c.markUnseen(seq);
    });
  }

  @override
  Future<List<Email>> check(String folder) async {
    final messages = await _session((c) async {
      if (folder == 'sent' && await _sentBox(c) == null) {
        return <mail.MimeMessage>[];
      }
      final box = await _select(c, folder);
      if (box.messagesExists == 0) return <mail.MimeMessage>[];
      return c.fetchMessages(mailbox: box, count: 30);
    });
    final fresh = [for (final m in messages) emailFrom(m, folder)];
    await _save((s) {
      final merged = mergeEmails(fresh, [
        for (final e in (s[folder] as List? ?? const []).whereType<Map>())
          Email.fromJson(e),
      ], max: 200);
      s[folder] = [for (final e in merged) e.toJson()];
      s['checked'] = {
        ...?s['checked'] as Map?,
        folder: DateTime.now().toUtc().toIso8601String(),
      };
      for (final (i, m) in messages.indexed) {
        if (fresh[i].snippet.isNotEmpty) {
          _keepOpened(s, _opened(fresh[i], m));
        }
      }
    });
    unawaited(_prefetch(folder));
    return keptIn(await _load(), folder);
  }

  bool _prefetching = false;

  /// Fetches the newest emails too big to come with the list, in the
  /// background, so they open at once too.
  Future<void> _prefetch(String folder) async {
    if (_prefetching) return;
    _prefetching = true;
    try {
      final s = await _load();
      final opened = s['opened'] as Map? ?? const {};
      final missing = [
        for (final e in keptIn(s, folder).take(15))
          if (!opened.containsKey(e.id)) e,
      ];
      if (missing.isEmpty) return;
      // Up to 2 MB each, so a big attachment isn't fetched on mobile data
      // before it's asked for.
      final got = await _session((c) async {
        final out = <OpenedEmail>[];
        for (final e in missing) {
          try {
            final m = await _fetch(
              c,
              e.id,
              how: mail.FetchPreference.fullWhenWithinSize,
            );
            final o = _opened(e, m);
            if (o.messages.first.body.isNotEmpty ||
                o.messages.first.html.isNotEmpty) {
              out.add(o);
            }
          } catch (_) {}
        }
        return out;
      }, wholeUpTo: 2 * 1024 * 1024);
      await _save((s) {
        for (final o in got) {
          _keepOpened(s, o);
        }
      });
    } catch (_) {
      // Fetched when opened instead.
    } finally {
      _prefetching = false;
    }
  }

  Future<mail.MimeMessage> _fetch(
    mail.MailClient c,
    String id, {
    mail.FetchPreference how = mail.FetchPreference.full,
  }) async {
    final at = parseDirectId(id);
    if (at == null) throw const EmailAgentError('This email has no id.');
    await _select(c, at.$1);
    final found = await c.fetchMessageSequence(
      mail.MessageSequence.fromId(at.$2, isUid: true),
      fetchPreference: how,
    );
    if (found.isEmpty) {
      throw const EmailAgentError(
        'This email is gone from the mail service (moved or deleted).',
      );
    }
    return found.first;
  }

  @override
  Future<OpenedEmail> openAndKeep(
    Email e, {
    void Function(OpenedEmail partial)? onProgress,
  }) async {
    final m = await _session((c) => _fetch(c, e.id));
    final o = _opened(e, m);
    await _save((s) => _keepOpened(s, o));
    return o;
  }

  @override
  Future<List<Email>> list({String folder = 'inbox', String query = ''}) async {
    if (query.trim().isEmpty) return check(folder);
    return _session((c) async {
      await _select(c, folder);
      final found = await c.searchMessages(
        mail.MailSearch(
          query.trim(),
          mail.SearchQueryType.allTextHeaders,
          pageSize: 30,
        ),
      );
      final emails = [for (final m in found.messages) emailFrom(m, folder)];
      emails.sort(
        (a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)),
      );
      return emails;
    });
  }

  mail.MailAddress get _from => mail.MailAddress(
    account.name.trim().isEmpty ? null : account.name.trim(),
    account.email,
  );

  Future<void> _send(mail.MailClient c, mail.MessageBuilder b) =>
      c.sendMessageBuilder(b, appendToSent: !account.keepsSentCopy);

  @override
  Future<void> reply(Email e, String text, {bool all = false}) =>
      _session((c) async {
        final original = await _fetch(c, e.id);
        final b = mail.MessageBuilder.prepareReplyToMessage(
          original,
          _from,
          replyAll: all,
          aliases: [_from],
        )..text = text;
        await _send(c, b);
        await c.markAnswered(
          mail.MessageSequence.fromId(original.uid!, isUid: true),
        );
      });

  @override
  Future<void> compose({
    required String to,
    required String subject,
    required String text,
  }) {
    final List<mail.MailAddress> recipients;
    try {
      recipients = parseAddresses(to);
    } on FormatException {
      throw EmailAgentError('"$to" isn\'t an email address.');
    }
    if (recipients.isEmpty) {
      throw const EmailAgentError('Who is it to?');
    }
    return _session((c) async {
      final b = mail.MessageBuilder()
        ..from = [_from]
        ..to = recipients
        ..subject = subject
        ..text = text;
      await _send(c, b);
    });
  }
}
