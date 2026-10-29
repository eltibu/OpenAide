// Runs against a real Open WebUI server; see server_sync_test.dart.
// Needs native/encryption built (cargo build --release there).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/channels/encrypted_chat_screen.dart';
import 'package:nexus_assistant/features/settings/settings_screen.dart'
    show meProvider;
import 'package:nexus_assistant/core/api/chat_socket.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/channels/channels_api.dart';
import 'package:nexus_assistant/features/channels/encrypted_conversation.dart';
import 'package:nexus_assistant/features/channels/mls.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null
      ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD'
      : !mlsAvailable
      ? 'Build native/encryption first'
      : null;

  Future<void> until(bool Function() done, String what) async {
    for (var i = 0; i < 100; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('Timed out waiting for $what');
  }

  test(
    'two people: start, join, talk both ways, receipts, leave',
    () async {
      HttpOverrides.global = null;
      final admin = OpenWebUiClient(baseUrl: url!);
      await admin.signIn(email!, password!);
      final config = (await admin.send(
        'GET',
        '/api/v1/auths/admin/config',
      ) as Map).cast<String, dynamic>();
      final wasOn = config['ENABLE_ENCRYPTED_CHANNELS'] == true;
      await admin.send(
        'POST',
        '/api/v1/auths/admin/config',
        body: {...config, 'ENABLE_ENCRYPTED_CHANNELS': true},
      );
      addTearDown(
        () => admin.send(
          'POST',
          '/api/v1/auths/admin/config',
          body: {...config, 'ENABLE_ENCRYPTED_CHANNELS': wasOn},
        ),
      );
      const friendEmail = 'crypto-friend@t.io';
      const friendPassword = 'Passw0rd!crypto';
      try {
        await admin.send(
          'POST',
          '/api/v1/auths/add',
          body: {
            'name': 'Crypto Friend',
            'email': friendEmail,
            'password': friendPassword,
            'role': 'admin',
          },
        );
      } on ApiException {
        // Made by an earlier run.
      }
      final friend = OpenWebUiClient(baseUrl: url);
      await friend.signIn(friendEmail, friendPassword);
      final friendId =
          '${(await friend.send('GET', '/api/v1/auths/') as Map)['id']}';
      final me = '${(await admin.send('GET', '/api/v1/auths/') as Map)['id']}';
      final dm = await ChannelsApi(admin).directMessage(friendId);

      final mySocket = ChatSocket(baseUrl: url, token: admin.token!);
      final theirSocket = ChatSocket(baseUrl: url, token: friend.token!);
      addTearDown(mySocket.dispose);
      addTearDown(theirSocket.dispose);
      expect(
        await mySocket.ready(timeout: const Duration(seconds: 10)),
        isNotNull,
      );
      expect(
        await theirSocket.ready(timeout: const Duration(seconds: 10)),
        isNotNull,
      );
      mySocket.joinChannels();
      theirSocket.joinChannels();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final mine = EncryptedConversation(
        SocketRelay(mySocket),
        channel: dm.id,
        user: me,
      );
      addTearDown(mine.dispose);
      await until(() => mine.status == EncryptedStatus.active, 'the start');
      expect(mine.isHost, isTrue);

      final session = await theirSocket.encryptedChatIn(dm.id);
      expect(session, isNotNull);
      final theirs = EncryptedConversation(
        SocketRelay(theirSocket),
        channel: dm.id,
        user: friendId,
        session: session,
      );
      addTearDown(theirs.dispose);
      await until(() => theirs.status == EncryptedStatus.active, 'the join');
      await until(() => mine.members.length == 2, 'the host to see two');
      expect(theirs.members.length, 2);
      expect(
        mine.members.map((m) => m.fingerprint).toSet(),
        theirs.members.map((m) => m.fingerprint).toSet(),
      );
      expect(mine.messages.where((m) => m.joined), hasLength(1));

      await mine.sendText('hello, sealed');
      await until(
        () => theirs.messages.any((m) => m.text == 'hello, sealed'),
        'the message',
      );
      expect(
        theirs.messages.firstWhere((m) => m.text == 'hello, sealed').userId,
        me,
      );
      await until(
        () => mine.messages
            .firstWhere((m) => m.text == 'hello, sealed')
            .received
            .isNotEmpty,
        'the receipt',
      );

      await theirs.sendTyping(true);
      await until(() => mine.typing.isNotEmpty, 'typing');
      await theirs.sendText('hi back');
      await until(
        () => mine.messages.any((m) => m.text == 'hi back'),
        'the answer',
      );
      expect(mine.typing, isEmpty);

      await theirs.updateKeys();
      await mine.sendText('after new keys');
      await until(
        () => theirs.messages.any((m) => m.text == 'after new keys'),
        'a message after new keys',
      );

      // Nothing of it is on the server.
      final saved = await ChannelsApi(admin).messages(dm.id);
      expect(saved.map((m) => m.content), isNot(contains('hello, sealed')));

      theirs.close();
      await until(() => mine.members.length == 1, 'the guest to leave');
      mine.close();
      expect(mine.status, EncryptedStatus.ended);
      expect(mine.messages, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await theirSocket.encryptedChatIn(dm.id), isNull);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets('the screen: start, someone joins, talk both ways', (
    tester,
  ) async {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    late OpenWebUiClient admin, friend;
    late Map<String, dynamic> config;
    late String me, friendId, channel;
    late ChatSocket mySocket, theirSocket;
    await tester.runAsync(() async {
      admin = OpenWebUiClient(baseUrl: url!);
      await admin.signIn(email!, password!);
      config = (await admin.send('GET', '/api/v1/auths/admin/config') as Map)
          .cast<String, dynamic>();
      await admin.send(
        'POST',
        '/api/v1/auths/admin/config',
        body: {...config, 'ENABLE_ENCRYPTED_CHANNELS': true},
      );
      try {
        await admin.send(
          'POST',
          '/api/v1/auths/add',
          body: {
            'name': 'Crypto Friend',
            'email': 'crypto-friend@t.io',
            'password': 'Passw0rd!crypto',
            'role': 'admin',
          },
        );
      } on ApiException {
        // Made by an earlier run.
      }
      friend = OpenWebUiClient(baseUrl: url);
      await friend.signIn('crypto-friend@t.io', 'Passw0rd!crypto');
      friendId = '${(await friend.send('GET', '/api/v1/auths/') as Map)['id']}';
      me = '${(await admin.send('GET', '/api/v1/auths/') as Map)['id']}';
      channel = (await ChannelsApi(admin).directMessage(friendId)).id;
      mySocket = ChatSocket(baseUrl: url, token: admin.token!);
      theirSocket = ChatSocket(baseUrl: url, token: friend.token!);
      await mySocket.ready(timeout: const Duration(seconds: 10));
      await theirSocket.ready(timeout: const Duration(seconds: 10));
      mySocket.joinChannels();
      theirSocket.joinChannels();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatSocketProvider.overrideWithValue(mySocket),
          meProvider.overrideWith((_) async => {'id': me, 'name': 'Me'}),
        ],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: EncryptedChatScreen(channel: channel, title: 'Crypto Friend'),
        ),
      ),
    );
    await settle(() => find.byTooltip('Participants').evaluate().isNotEmpty);
    expect(find.byTooltip('Participants'), findsOneWidget);

    String? session;
    await tester.runAsync(() async {
      session = await theirSocket.encryptedChatIn(channel);
    });
    final theirs = EncryptedConversation(
      SocketRelay(theirSocket),
      channel: channel,
      user: friendId,
      session: session,
    );
    await settle(() => find.text('Crypto Friend joined').evaluate().isNotEmpty);
    expect(find.text('Crypto Friend joined'), findsOneWidget);

    await tester.runAsync(() async => theirs.sendText('knock knock'));
    await settle(() => find.text('knock knock').evaluate().isNotEmpty);
    expect(find.text('knock knock'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'who is there');
    await tester.tap(find.byTooltip('Send message'));
    await settle(() => theirs.messages.any((m) => m.text == 'who is there'));
    expect(theirs.messages.map((m) => m.text), contains('who is there'));
    await settle(() => find.byIcon(Icons.done_all).evaluate().isNotEmpty);
    expect(find.byIcon(Icons.done_all), findsOneWidget);

    await tester.tap(find.byTooltip('Participants'));
    await tester.pumpAndSettle();
    expect(find.text('Codes match'), findsOneWidget);
    await tester.tap(find.text('Codes match'));
    await tester.pump();
    expect(find.text('Verified'), findsOneWidget);
    Navigator.of(tester.element(find.text('Verified'))).pop();
    await tester.pumpAndSettle();

    // Leaving ends it for the guest too.
    await tester.tap(find.byTooltip('Leave'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && theirs.status != EncryptedStatus.ended; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    expect(theirs.status, EncryptedStatus.ended);
    theirs.dispose();
    await tester.runAsync(() async {
      await admin.send('POST', '/api/v1/auths/admin/config', body: {...config});
      mySocket.dispose();
      theirSocket.dispose();
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }, skip: skip != null);
}
