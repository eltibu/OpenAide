import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../email/direct_mail.dart' show DirectMailStore;
import '../providers/ai_providers_screen.dart';
import 'mail_accounts.dart';
import 'mail_sign_in.dart';
import '../../core/i18n/app_strings.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(text))));

/// Settings > Accounts: services the app signs in to itself, on the phone,
/// so they work without an Open WebUI server.
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mail = ref.watch(mailAccountsProvider);
    final muted = context.nexus.muted;
    final accounts = mail.value?.accounts ?? const <MailAccountConfig>[];
    void open(Widget page) =>
        Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
    return Scaffold(
      appBar: AppBar(title: const T('Accounts')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: T('Email', style: Theme.of(context).textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: T(
              'The app reads and sends this mail itself. The password stays '
              'on this phone, in its secure storage.',
              style: TextStyle(color: muted, fontSize: 13),
            ),
          ),
          if (mail.isLoading && accounts.isEmpty)
            const LinearProgressIndicator(minHeight: 2),
          for (final a in accounts)
            ListTile(
              leading: const Icon(Icons.mail_outline),
              title: Text(a.email),
              subtitle: Text(
                [
                  presetFor(a.email)?.label ?? a.imapHost,
                  if (mail.value?.current?.email == a.email) 'shown in Email',
                ].join(' · '),
              ),
              onTap: () => open(AddMailAccount(editing: a)),
              trailing: PopupMenuButton<String>(
                onSelected: (v) async {
                  final n = ref.read(mailAccountsProvider.notifier);
                  if (v == 'show') {
                    await n.show(a.email);
                    if (context.mounted) {
                      _say(context, 'Email shows ${a.email}');
                    }
                  } else if (v == 'remove') {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (d) => AlertDialog(
                        title: Text('Remove ${a.email}?'),
                        content: const T(
                          'The app forgets its password and the mail it '
                          'kept. Nothing is deleted from the account itself.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(d, false),
                            child: const T('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(d, true),
                            child: const T('Remove'),
                          ),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    await n.remove(a.email);
                    await DirectMailStore(a.email).clear();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'show', child: T('Show in Email')),
                  PopupMenuItem(value: 'remove', child: T('Remove')),
                ],
              ),
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const T('Add an email account'),
            subtitle: const T('Gmail, Outlook, iCloud, Yahoo or any IMAP'),
            onTap: () => open(const AddMailAccount()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const T('AI providers'),
            subtitle: const T('OpenRouter, Claude and OpenAI'),
            onTap: () => open(const AiProvidersScreen()),
          ),
        ],
      ),
    );
  }
}

/// Adds an email account (or changes one): the address and an app
/// password are enough for known services; others find their servers
/// themselves or take them by hand.
class AddMailAccount extends ConsumerStatefulWidget {
  const AddMailAccount({super.key, this.editing});
  final MailAccountConfig? editing;

  @override
  ConsumerState<AddMailAccount> createState() => _AddMailAccountState();
}

class _AddMailAccountState extends ConsumerState<AddMailAccount> {
  late final _email = TextEditingController(text: widget.editing?.email);
  final _password = TextEditingController();
  late final _name = TextEditingController(text: widget.editing?.name);
  late final _login = TextEditingController(text: widget.editing?.login);
  late final _imapHost = TextEditingController(text: widget.editing?.imapHost);
  late final _imapPort = TextEditingController(
    text: '${widget.editing?.imapPort ?? 993}',
  );
  late final _smtpHost = TextEditingController(text: widget.editing?.smtpHost);
  late final _smtpPort = TextEditingController(
    text: '${widget.editing?.smtpPort ?? 465}',
  );
  late bool _startTls = widget.editing?.smtpStartTls ?? false;
  bool _servers = false;
  bool _busy = false;
  bool _hide = true;
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _email,
      _password,
      _name,
      _login,
      _imapHost,
      _imapPort,
      _smtpHost,
      _smtpPort,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(MailAccountConfig a) {
    _login.text = a.login;
    _imapHost.text = a.imapHost;
    _imapPort.text = '${a.imapPort}';
    _smtpHost.text = a.smtpHost;
    _smtpPort.text = '${a.smtpPort}';
    _startTls = a.smtpStartTls;
  }

  Future<void> _save() async {
    final email = _email.text.trim();
    final password = _password.text.isEmpty
        ? widget.editing?.password ?? ''
        : _password.text.replaceAll(' ', '');
    if (!email.contains('@')) {
      return setState(() => _error = 'Enter your email address.');
    }
    if (password.isEmpty) {
      return setState(() => _error = 'Enter the app password.');
    }
    final preset = presetFor(email);
    if (preset?.signInOnly == true && widget.editing?.oauth == null) {
      return setState(() => _error = preset!.help);
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    MailAccountConfig? account;
    if (_servers && _imapHost.text.trim().isNotEmpty) {
      account = MailAccountConfig(
        email: email,
        password: password,
        name: _name.text.trim(),
        login: _login.text.trim(),
        imapHost: _imapHost.text.trim(),
        imapPort: int.tryParse(_imapPort.text.trim()) ?? 993,
        smtpHost: _smtpHost.text.trim(),
        smtpPort: int.tryParse(_smtpPort.text.trim()) ?? 465,
        smtpStartTls: _startTls,
      );
    } else if (widget.editing != null && widget.editing!.email == email) {
      account = widget.editing!.copyWith(
        password: password,
        name: _name.text.trim(),
      );
    } else {
      account = await guessServers(email, password, name: _name.text.trim());
    }
    if (!mounted) return;
    if (account == null) {
      return setState(() {
        _busy = false;
        _servers = true;
        _error =
            'Couldn\'t find the mail servers for this address. Enter them '
            'below (your mail service lists them as IMAP and SMTP).';
      });
    }
    _fill(account);
    try {
      await testMailAccount(account);
    } catch (e) {
      if (!mounted) return;
      return setState(() {
        _busy = false;
        _error =
            '$e${preset?.appPasswordUrl != null ? '\n\n${preset!.help}' : ''}';
      });
    }
    await ref.read(mailAccountsProvider.notifier).save(account);
    if (!mounted) return;
    _say(context, '${account.email} added');
    Navigator.pop(context);
  }

  GoogleSignIn? _google;

  @override
  void deactivate() {
    _google?.cancel();
    super.deactivate();
  }

  /// Signs in with Google or Microsoft instead of an app password, then
  /// adds the account it opened.
  Future<void> _signIn(MailSignIn provider) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final cancel = Completer<void>();
    try {
      final MailGrant grant;
      if (provider == MailSignIn.microsoft) {
        final code = await startMicrosoftSignIn();
        if (!mounted) return;
        final waiting = waitForMicrosoftSignIn(code, cancelled: cancel.future);
        var open = true;
        void close() {
          if (open && mounted) Navigator.of(context, rootNavigator: true).pop();
        }

        unawaited(waiting.then((_) => close(), onError: (_) => close()));
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (d) => DeviceCodeDialog(
            code: code,
            site: 'Microsoft',
            onCancel: () {
              if (!cancel.isCompleted) cancel.complete();
              Navigator.pop(d);
            },
          ),
        );
        open = false;
        grant = await waiting;
      } else {
        final sign = _google = await GoogleSignIn.start(
          loginHint: _email.text.trim(),
        );
        if (mounted) setState(() {});
        grant = await sign.grant;
      }
      final editing = widget.editing;
      if (editing != null &&
          editing.email.toLowerCase() != grant.email.toLowerCase()) {
        throw MailSignInError(
          'That signed in as ${grant.email}, not ${editing.email}.',
        );
      }
      await forgetMailSignIn(grant.email);
      rememberAccessToken(grant);
      final consumer = presetFor(grant.email) != null;
      final account = MailAccountConfig(
        email: grant.email,
        password: grant.refreshToken,
        name: _name.text.trim().isNotEmpty ? _name.text.trim() : grant.name,
        signIn: provider.id,
        imapHost: provider == MailSignIn.google
            ? 'imap.gmail.com'
            : 'outlook.office365.com',
        smtpHost: provider == MailSignIn.google
            ? 'smtp.gmail.com'
            : consumer
            ? 'smtp-mail.outlook.com'
            : 'smtp.office365.com',
        smtpPort: provider == MailSignIn.google ? 465 : 587,
        smtpStartTls: provider == MailSignIn.microsoft,
      );
      await testMailAccount(account);
      await ref.read(mailAccountsProvider.notifier).save(account);
      if (!mounted) return;
      _say(context, '${account.email} added');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (!cancel.isCompleted) cancel.complete();
      _google = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Widget> _signInButtons(MailAccountConfig? editing) {
    final providers = [
      for (final p in MailSignIn.values)
        if (p.available && (editing == null || editing.oauth == p)) p,
    ];
    if (providers.isEmpty) return const [];
    return [
      for (final p in providers) ...[
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _signIn(p),
          icon: const Icon(Icons.login),
          label: Text(
            editing == null ? 'Sign in with ${p.label}' : 'Sign in again',
          ),
        ),
        const SizedBox(height: 8),
      ],
      if (_google != null)
        Row(
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: T('Approve OpenAide in the browser, then come back.'),
            ),
            TextButton(
              onPressed: () => _google?.cancel(),
              child: const T('Cancel'),
            ),
          ],
        ),
      if (editing == null) ...[
        const SizedBox(height: 4),
        T(
          'Or add any account with its app password:',
          style: TextStyle(color: context.nexus.muted, fontSize: 13),
        ),
        const SizedBox(height: 12),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final preset = presetFor(_email.text.trim());
    final signedIn = widget.editing?.oauth;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.editing == null ? 'Add email' : 'Email account'),
      ),
      body: AbsorbPointer(
        absorbing: _busy && _google == null,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (widget.editing == null) ..._signInButtons(null),
            TextField(
              controller: _email,
              enabled: widget.editing == null,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: tr('Email address'),
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            if (signedIn != null) ...[
              T(
                'Signed in with ${signedIn.label}. No password is kept.',
                style: TextStyle(color: muted, fontSize: 13),
              ),
              const SizedBox(height: 8),
              ..._signInButtons(widget.editing),
            ] else
              TextField(
                controller: _password,
                obscureText: _hide,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: widget.editing == null
                      ? 'App password'
                      : 'App password (empty keeps the saved one)',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _hide ? 'Show' : 'Hide',
                    icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _hide = !_hide),
                  ),
                ),
              ),
            if (signedIn == null &&
                preset != null &&
                preset.help.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(preset.help, style: TextStyle(color: muted, fontSize: 13)),
              if (preset.appPasswordUrl != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse(preset.appPasswordUrl!),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text('Make a ${preset.label} app password'),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: tr('Your name on sent mail (optional)'),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            ExpansionTile(
              key: ValueKey(_servers),
              initiallyExpanded: _servers,
              tilePadding: EdgeInsets.zero,
              title: const T('Mail servers'),
              subtitle: T(
                'Found by themselves for most addresses',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              onExpansionChanged: (open) => _servers = open,
              children: [
                TextField(
                  controller: _login,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr('Sign-in name (if not the address)'),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _imapHost,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: tr('IMAP server'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _imapPort,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: tr('Port')),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _smtpHost,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: tr('SMTP server'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _smtpPort,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: tr('Port')),
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const T('SMTP uses STARTTLS (port 587)'),
                  value: _startTls,
                  onChanged: (v) => setState(() {
                    _startTls = v;
                    _smtpPort.text = v ? '587' : '465';
                  }),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(widget.editing == null ? 'Sign in' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
