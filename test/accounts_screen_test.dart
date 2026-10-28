import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/accounts/accounts_screen.dart';
import 'package:nexus_assistant/features/accounts/mail_accounts.dart';

void main() {
  testWidgets('lists the accounts kept on the phone', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'nexusAccount.mail': jsonEncode([
        const MailAccountConfig(
          email: 'joel@gmail.com',
          password: 'abcd',
          imapHost: 'imap.gmail.com',
          smtpHost: 'smtp.gmail.com',
        ).toJson(),
      ]),
    });
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: AccountsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('joel@gmail.com'), findsOneWidget);
    expect(find.text('Gmail · shown in Email'), findsOneWidget);
    expect(find.text('Add an email account'), findsOneWidget);
  });

  testWidgets('a Gmail address shows how to make an app password', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: AddMailAccount(),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'joel@gmail.com');
    await tester.pump();
    expect(find.text('Make a Gmail app password'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'joel@outlook.com');
    await tester.enterText(find.byType(TextField).at(1), 'pw');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.textContaining('need a Microsoft sign-in'), findsWidgets);
  });
}
