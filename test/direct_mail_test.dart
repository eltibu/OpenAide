import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as mail;

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/accounts/mail_accounts.dart';
import 'package:nexus_assistant/features/email/direct_mail.dart';

void main() {
  test('HTML mail reads as plain text', () {
    expect(
      htmlToText(
        '<html><head><style>p{color:red}</style></head><body>'
        '<p>Hi&nbsp;Joel,</p><p>See <b>this</b> &amp; that.<br>Bye</p>'
        '<ul><li>one</li><li>two</li></ul></body></html>',
      ),
      'Hi Joel,\nSee this & that.\nBye\n• one\n• two',
    );
    expect(htmlToText('caf&#233; &#x2764;'), 'café ❤');
  });

  test('ids carry the folder and the UID', () {
    expect(directId('sent', 42), 'sent:42');
    expect(parseDirectId('sent:42'), ('sent', 42));
    expect(parseDirectId('nexus-id'), isNull);
  });

  test('known services need only the address', () {
    expect(presetFor('Joel@Gmail.com')?.imapHost, 'imap.gmail.com');
    expect(presetFor('a@icloud.com')?.smtpStartTls, isTrue);
    expect(presetFor('a@outlook.com')?.signInOnly, isTrue);
    expect(presetFor('a@example.org'), isNull);
  });

  test('Gmail keeps its own copy of sent mail', () {
    const gmail = MailAccountConfig(
      email: 'a@gmail.com',
      password: 'x',
      imapHost: 'imap.gmail.com',
      smtpHost: 'smtp.gmail.com',
    );
    const other = MailAccountConfig(
      email: 'a@fastmail.com',
      password: 'x',
      imapHost: 'imap.fastmail.com',
      smtpHost: 'smtp.fastmail.com',
    );
    expect(gmail.keepsSentCopy, isTrue);
    expect(other.keepsSentCopy, isFalse);
    expect(
      MailAccountConfig.fromJson(gmail.toJson()).smtpHost,
      'smtp.gmail.com',
    );
  });

  test('Email shows the chosen account, else the first one', () {
    const a = MailAccountConfig(
      email: 'a@x.com',
      password: '',
      imapHost: 'i',
      smtpHost: 's',
    );
    const b = MailAccountConfig(
      email: 'b@x.com',
      password: '',
      imapHost: 'i',
      smtpHost: 's',
    );
    expect(const MailAccounts(accounts: [a, b]).current, a);
    expect(const MailAccounts(accounts: [a, b], source: 'b@x.com').current, b);
    expect(
      const MailAccounts(accounts: [a, b], source: nexusMailSource).current,
      isNull,
    );
    expect(const MailAccounts().current, isNull);
  });

  // Against a real IMAP/SMTP server: run GreenMail (IMAPS on 3993)
  // and a user joel@localhost / secret, then set NEXUS_TEST_MAIL_CERT to
  // its certificate (PEM).
  final cert = Platform.environment['NEXUS_TEST_MAIL_CERT'];
  test(
    'sends, lists, opens, replies and marks read over IMAP and SMTP',
    () async {
      SecurityContext.defaultContext.setTrustedCertificates(cert!);
      final dir = await Directory.systemTemp.createTemp('mail');
      const account = MailAccountConfig(
        email: 'joel@localhost',
        password: 'secret',
        imapHost: 'localhost',
        imapPort: 3993,
        smtpHost: 'localhost',
        // GreenMail's own SMTPS sends its greeting in two pieces, which
        // enough_mail doesn't join, so sending goes through a TLS relay
        // into it (aiosmtpd, port 4465).
        smtpPort: 4465,
      );
      await testMailAccount(account);
      await expectLater(
        testMailAccount(account.copyWith(password: 'wrong')),
        throwsA(isA<MailAccountError>()),
      );

      final box = DirectMail(
        account,
        store: DirectMailStore(account.email, folder: dir),
      );
      await box.compose(
        to: 'Joel <joel@localhost>',
        subject: 'Hello from the test',
        text: 'First line\nSecond line',
      );
      final inbox = await box.check('inbox');
      final hello = inbox.firstWhere((e) => e.subject == 'Hello from the test');
      expect(hello.unread, isTrue);
      expect(hello.snippet, 'First line Second line');
      expect(hello.from, 'joel@localhost');

      // Kept with the list, so it opens without a wait.
      final kept = await box.keptOpen(hello);
      expect(kept?.messages.single.body, 'First line\nSecond line');
      final opened = await box.openAndKeep(hello);
      expect(opened.messages.single.body, 'First line\nSecond line');

      await box.setRead(hello);
      final again = await box.check('inbox');
      expect(again.firstWhere((e) => e.id == hello.id).unread, isFalse);

      await box.reply(hello, 'Got it');
      final after = await box.check('inbox');
      expect(after.any((e) => e.subject == 'Re: Hello from the test'), isTrue);

      // GreenMail has no Sent folder: an empty list, not an error.
      expect(await box.check('sent'), isEmpty);

      final found = await box.list(query: 'Hello from');
      expect(found, isNotEmpty);

      // The phone's copy shows the list before anything is fetched.
      final copy = await DirectMail(
        account,
        store: DirectMailStore(account.email, folder: dir),
      ).kept('inbox');
      expect(copy.length, after.length);

      // An HTML email with an inline picture shows as sent, picture in.
      final client = mail.MailClient(account.toMailAccount());
      await client.connect();
      for (final name in ['Trash', 'Archive']) {
        try {
          await client.createMailbox(name);
        } catch (_) {}
      }
      final b =
          mail.MessageBuilder.prepareMultipartAlternativeMessage(
              plainText: 'Plain version',
              htmlText: '<p>Hi <b>Joel</b></p><img src="cid:logo@x">',
            )
            ..from = [mail.MailAddress('Shop', 'joel@localhost')]
            ..to = [mail.MailAddress(null, 'joel@localhost')]
            ..subject = 'Newsletter';
      b
          .addBinary(
            Uint8List.fromList([137, 80, 78, 71]),
            mail.MediaSubtype.imagePng.mediaType,
            filename: 'logo.png',
            disposition: mail.ContentDispositionHeader.from(
              mail.ContentDisposition.inline,
            ),
          )
          .setHeader('Content-ID', '<logo@x>');
      b.addBinary(
        Uint8List.fromList(utf8.encode('a,b')),
        mail.MediaSubtype.textPlain.mediaType,
        filename: 'report.csv',
      );
      await client.sendMessageBuilder(b, appendToSent: false);
      await client.disconnect();

      final news = (await box.check('inbox'))
          .firstWhere((e) => e.subject == 'Newsletter');
      final shown = (await box.keptOpen(news))!.messages.single;
      expect(shown.html, contains('<b>Joel</b>'));
      expect(shown.html, contains('data:image/png;base64,iVBORw=='));
      expect(shown.attachments, contains('report.csv'));
      expect(shown.body, 'Plain version');

      await box.setStarred(news, true);
      expect(
        (await box.check('inbox')).firstWhere((e) => e.id == news.id).starred,
        isTrue,
      );

      await box.forward(news, to: 'joel@localhost', text: 'Look at this');
      final fwd = (await box.check('inbox'))
          .firstWhere((e) => e.subject == 'Fwd: Newsletter');
      expect(
        (await box.keptOpen(fwd))!.messages.single.body,
        startsWith('Look at this'),
      );

      await box.archive(news);
      await box.trash(fwd);
      final left = await box.check('inbox');
      expect(left.any((e) => e.id == news.id || e.id == fwd.id), isFalse);
      await dir.delete(recursive: true);
    },
    skip: cert == null ? 'No test mail server' : false,
  );
}
