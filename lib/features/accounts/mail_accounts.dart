/// Email accounts the app reads and sends with itself, over IMAP and SMTP,
/// with no Open WebUI server in between. They live on the phone only, in
/// its secure storage, so they work for anyone, with or without a server.
library;

import 'dart:convert';

import 'package:enough_mail/enough_mail.dart' as mail;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One email account: where its mail is and how to sign in.
class MailAccountConfig {
  const MailAccountConfig({
    required this.email,
    required this.password,
    required this.imapHost,
    required this.smtpHost,
    this.name = '',
    this.login = '',
    this.imapPort = 993,
    this.smtpPort = 465,
    this.smtpStartTls = false,
  });

  factory MailAccountConfig.fromJson(Map j) => MailAccountConfig(
    email: '${j['email'] ?? ''}',
    password: '${j['password'] ?? ''}',
    name: '${j['name'] ?? ''}',
    login: '${j['login'] ?? ''}',
    imapHost: '${j['imapHost'] ?? ''}',
    imapPort: (j['imapPort'] as num?)?.toInt() ?? 993,
    smtpHost: '${j['smtpHost'] ?? ''}',
    smtpPort: (j['smtpPort'] as num?)?.toInt() ?? 465,
    smtpStartTls: j['smtpStartTls'] == true,
  );

  Map<String, dynamic> toJson() => {
    'email': email,
    'password': password,
    'name': name,
    'login': login,
    'imapHost': imapHost,
    'imapPort': imapPort,
    'smtpHost': smtpHost,
    'smtpPort': smtpPort,
    'smtpStartTls': smtpStartTls,
  };

  final String email;

  /// For Gmail, iCloud and Yahoo an app password, not the account's own.
  final String password;

  /// The name shown on mail sent from it.
  final String name;

  /// The sign-in name, when it isn't the address.
  final String login;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;

  /// SMTP starts plain and switches to TLS (port 587) instead of TLS from
  /// the start (465).
  final bool smtpStartTls;

  /// Gmail keeps a copy of what is sent over SMTP itself, so the app must
  /// not add a second one to Sent.
  bool get keepsSentCopy =>
      imapHost.endsWith('gmail.com') || imapHost.endsWith('googlemail.com');

  mail.MailAccount toMailAccount() => mail.MailAccount.fromManualSettings(
    name: email,
    email: email,
    userName: name,
    loginName: login.isEmpty ? email : login,
    password: password,
    incomingHost: imapHost,
    incomingPort: imapPort,
    outgoingHost: smtpHost,
    outgoingPort: smtpPort,
    outgoingSocketType: smtpStartTls
        ? mail.SocketType.starttls
        : mail.SocketType.ssl,
    outgoingClientDomain: 'nexus-assistant.app',
  );

  MailAccountConfig copyWith({String? password, String? name}) =>
      MailAccountConfig(
        email: email,
        password: password ?? this.password,
        name: name ?? this.name,
        login: login,
        imapHost: imapHost,
        imapPort: imapPort,
        smtpHost: smtpHost,
        smtpPort: smtpPort,
        smtpStartTls: smtpStartTls,
      );
}

/// Known mail services: their servers, and where to make an app password.
class MailPreset {
  const MailPreset({
    required this.label,
    required this.imapHost,
    required this.smtpHost,
    this.smtpPort = 465,
    this.smtpStartTls = false,
    this.appPasswordUrl,
    this.help = '',
    this.signInOnly = false,
  });

  final String label;
  final String imapHost;
  final String smtpHost;
  final int smtpPort;
  final bool smtpStartTls;
  final String? appPasswordUrl;
  final String help;

  /// The service no longer takes passwords over IMAP; it needs its own
  /// sign-in (OAuth).
  final bool signInOnly;
}

const _gmail = MailPreset(
  label: 'Gmail',
  imapHost: 'imap.gmail.com',
  smtpHost: 'smtp.gmail.com',
  appPasswordUrl: 'https://myaccount.google.com/apppasswords',
  help:
      'Gmail needs an app password, not your Google password. Turn on '
      '2-Step Verification, then make one at Google Account > App '
      'passwords and paste the 16 letters here.',
);

const _outlook = MailPreset(
  label: 'Outlook',
  imapHost: 'outlook.office365.com',
  smtpHost: 'smtp-mail.outlook.com',
  smtpPort: 587,
  smtpStartTls: true,
  signInOnly: true,
  help:
      'Outlook.com and Hotmail no longer accept passwords from mail apps. '
      'They need a Microsoft sign-in, which is coming to Accounts.',
);

const mailPresets = <String, MailPreset>{
  'gmail.com': _gmail,
  'googlemail.com': _gmail,
  'icloud.com': MailPreset(
    label: 'iCloud',
    imapHost: 'imap.mail.me.com',
    smtpHost: 'smtp.mail.me.com',
    smtpPort: 587,
    smtpStartTls: true,
    appPasswordUrl: 'https://account.apple.com/account/manage',
    help:
        'iCloud needs an app-specific password. Make one at Apple Account '
        '> Sign-In and Security > App-Specific Passwords.',
  ),
  'me.com': MailPreset(
    label: 'iCloud',
    imapHost: 'imap.mail.me.com',
    smtpHost: 'smtp.mail.me.com',
    smtpPort: 587,
    smtpStartTls: true,
    appPasswordUrl: 'https://account.apple.com/account/manage',
    help: 'iCloud needs an app-specific password.',
  ),
  'mac.com': MailPreset(
    label: 'iCloud',
    imapHost: 'imap.mail.me.com',
    smtpHost: 'smtp.mail.me.com',
    smtpPort: 587,
    smtpStartTls: true,
    appPasswordUrl: 'https://account.apple.com/account/manage',
    help: 'iCloud needs an app-specific password.',
  ),
  'yahoo.com': MailPreset(
    label: 'Yahoo',
    imapHost: 'imap.mail.yahoo.com',
    smtpHost: 'smtp.mail.yahoo.com',
    appPasswordUrl: 'https://login.yahoo.com/account/security',
    help:
        'Yahoo needs an app password: Account Security > Generate app '
        'password.',
  ),
  'aol.com': MailPreset(
    label: 'AOL',
    imapHost: 'imap.aol.com',
    smtpHost: 'smtp.aol.com',
    appPasswordUrl: 'https://login.aol.com/account/security',
    help: 'AOL needs an app password: Account Security > App passwords.',
  ),
  'fastmail.com': MailPreset(
    label: 'Fastmail',
    imapHost: 'imap.fastmail.com',
    smtpHost: 'smtp.fastmail.com',
    appPasswordUrl: 'https://app.fastmail.com/settings/security/apps',
    help: 'Fastmail needs an app password: Settings > Privacy & Security.',
  ),
  'zoho.com': MailPreset(
    label: 'Zoho',
    imapHost: 'imap.zoho.com',
    smtpHost: 'smtp.zoho.com',
  ),
  'gmx.com': MailPreset(
    label: 'GMX',
    imapHost: 'imap.gmx.com',
    smtpHost: 'mail.gmx.com',
    smtpPort: 587,
    smtpStartTls: true,
  ),
  'proton.me': MailPreset(
    label: 'Proton',
    imapHost: '127.0.0.1',
    smtpHost: '127.0.0.1',
    signInOnly: true,
    help:
        'Proton Mail only works over IMAP through Proton Bridge on a '
        'computer, not from a phone.',
  ),
  'outlook.com': _outlook,
  'hotmail.com': _outlook,
  'live.com': _outlook,
  'msn.com': _outlook,
};

/// The known service for [email], by its domain.
MailPreset? presetFor(String email) {
  final at = email.lastIndexOf('@');
  if (at < 0) return null;
  return mailPresets[email.substring(at + 1).trim().toLowerCase()];
}

/// The servers for [email]: a known service's, or what its domain
/// publishes (autoconfig), or null to ask.
Future<MailAccountConfig?> guessServers(
  String email,
  String password, {
  String name = '',
}) async {
  final preset = presetFor(email);
  if (preset != null) {
    return MailAccountConfig(
      email: email,
      password: password,
      name: name,
      imapHost: preset.imapHost,
      smtpHost: preset.smtpHost,
      smtpPort: preset.smtpPort,
      smtpStartTls: preset.smtpStartTls,
    );
  }
  try {
    final config = await mail.Discover.discover(
      email,
      forceSslConnection: true,
    ).timeout(const Duration(seconds: 20));
    final imap = config?.preferredIncomingImapServer;
    final smtp = config?.preferredOutgoingSmtpServer;
    if (config == null ||
        config.isFromInsecureSource ||
        imap == null ||
        smtp == null) {
      return null;
    }
    return MailAccountConfig(
      email: email,
      password: password,
      name: name,
      login: _login(imap.username, email),
      imapHost: imap.hostname,
      imapPort: imap.port,
      smtpHost: smtp.hostname,
      smtpPort: smtp.port,
      smtpStartTls: smtp.socketType == mail.SocketType.starttls,
    );
  } catch (_) {
    return null;
  }
}

/// Autoconfig names the sign-in with placeholders such as %EMAILADDRESS%.
String _login(String template, String email) {
  final local = email.split('@').first;
  final t = template
      .replaceAll('%EMAILADDRESS%', email)
      .replaceAll('%EMAILLOCALPART%', local);
  return t == email ? '' : t;
}

/// Signs in to both servers, so a wrong password or server shows when the
/// account is added, not later. Throws with what went wrong.
Future<void> testMailAccount(MailAccountConfig a) async {
  final imap = mail.ImapClient();
  try {
    await imap.connectToServer(
      a.imapHost,
      a.imapPort,
      timeout: const Duration(seconds: 20),
    );
    await imap.login(a.login.isEmpty ? a.email : a.login, a.password);
  } on mail.ImapException catch (e) {
    throw MailAccountError(
      'Couldn\'t sign in to ${a.imapHost}: ${e.message ?? e}',
    );
  } catch (e) {
    throw MailAccountError('Couldn\'t reach ${a.imapHost}: $e');
  } finally {
    try {
      await imap.disconnect();
    } catch (_) {}
  }
  final smtp = mail.SmtpClient('nexus-assistant.app');
  try {
    await smtp.connectToServer(
      a.smtpHost,
      a.smtpPort,
      isSecure: !a.smtpStartTls,
      timeout: const Duration(seconds: 20),
    );
    await smtp.ehlo();
    if (a.smtpStartTls) await smtp.startTls();
    final login = a.login.isEmpty ? a.email : a.login;
    final info = smtp.serverInfo;
    await smtp.authenticate(
      login,
      a.password,
      info.supportsAuth(mail.AuthMechanism.plain)
          ? mail.AuthMechanism.plain
          : info.supportsAuth(mail.AuthMechanism.login)
          ? mail.AuthMechanism.login
          : mail.AuthMechanism.cramMd5,
    );
  } on mail.SmtpException catch (e) {
    throw MailAccountError(
      'Signed in to read mail, but not to send it (${a.smtpHost}): '
      '${e.message ?? e}',
    );
  } catch (e) {
    throw MailAccountError('Couldn\'t reach ${a.smtpHost}: $e');
  } finally {
    try {
      await smtp.disconnect();
    } catch (_) {}
  }
}

class MailAccountError implements Exception {
  const MailAccountError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The email accounts kept on the phone, and which mail the Email screen
/// shows (`nexus` for mail through the server, or an account's address).
class MailAccounts {
  const MailAccounts({this.accounts = const [], this.source});
  final List<MailAccountConfig> accounts;
  final String? source;

  /// The account the Email screen reads, or null for mail through Nexus.
  /// With no choice made, the first account on the phone.
  MailAccountConfig? get current {
    if (source == nexusMailSource) return null;
    return accounts.where((a) => a.email == source).firstOrNull ??
        accounts.firstOrNull;
  }
}

const nexusMailSource = 'nexus';

class MailAccountsNotifier extends AsyncNotifier<MailAccounts> {
  static const _storage = FlutterSecureStorage();
  static const _accountsKey = 'nexusAccount.mail';
  static const _sourceKey = 'nexusAccount.mailSource';

  @override
  Future<MailAccounts> build() async {
    try {
      final text = await _storage.read(key: _accountsKey);
      final list = text == null ? null : jsonDecode(text);
      return MailAccounts(
        accounts: [
          for (final j in (list is List ? list : const []).whereType<Map>())
            MailAccountConfig.fromJson(j),
        ],
        source: await _storage.read(key: _sourceKey),
      );
    } catch (_) {
      return const MailAccounts();
    }
  }

  Future<void> _write(MailAccounts m) async {
    await _storage.write(
      key: _accountsKey,
      value: jsonEncode([for (final a in m.accounts) a.toJson()]),
    );
    if (m.source == null) {
      await _storage.delete(key: _sourceKey);
    } else {
      await _storage.write(key: _sourceKey, value: m.source);
    }
    state = AsyncData(m);
  }

  /// Adds [a], or replaces the account with its address, and shows its
  /// mail in Email.
  Future<void> save(MailAccountConfig a) async {
    final now = await future;
    await _write(
      MailAccounts(
        accounts: [
          for (final o in now.accounts)
            if (o.email != a.email) o,
          a,
        ],
        source: a.email,
      ),
    );
  }

  Future<void> remove(String email) async {
    final now = await future;
    await _write(
      MailAccounts(
        accounts: [
          for (final o in now.accounts)
            if (o.email != email) o,
        ],
        source: now.source == email ? null : now.source,
      ),
    );
  }

  /// Which mail Email shows: [nexusMailSource] or an account's address.
  Future<void> show(String source) async {
    final now = await future;
    await _write(MailAccounts(accounts: now.accounts, source: source));
  }
}

final mailAccountsProvider =
    AsyncNotifierProvider<MailAccountsNotifier, MailAccounts>(
      MailAccountsNotifier.new,
    );
