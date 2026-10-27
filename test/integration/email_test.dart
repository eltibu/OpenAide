// Runs against a real Open WebUI server; see server_sync_test.dart. The
// test server's model answers the app's email requests with fixed JSON.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/email/email_agent.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test(
    'email goes through Nexus in a chat of its own',
    () async {
      final client = OpenWebUiClient(baseUrl: url!);
      await client.signIn(email!, password!);
      final model = (await client.models()).first.id;
      final agent = EmailAgent(client, model: model, options: const {});

      final inbox = await agent.list();
      expect(inbox.map((e) => e.subject), [
        'Field trip forms',
        'Your statement',
      ]);
      expect(inbox.first.fromName, 'Ana Ruiz');
      expect(inbox.first.unread, isTrue);
      expect(inbox.first.note, contains('Friday'));

      final opened = await agent.open(inbox.first);
      expect(opened.messages.single.body, contains('field trip forms'));
      expect(opened.suggestedReply, startsWith('Hi Ana'));

      await agent.reply(inbox.first, 'Sure, Thursday.');

      // One chat, reused, remembered in the settings, holding every turn.
      final ui = (await client.userSettings())['ui'] as Map;
      final id = ui[emailChatKey] as String;
      final chat = await client.chat(id);
      expect(chat.title, emailChatTitle);
      expect(chat.thread.where((m) => m.role == 'user').length, 3);

      // A fresh agent finds the same chat again.
      final again = EmailAgent(client, model: model, options: const {});
      await again.list(folder: 'sent');
      expect((await client.chat(id)).thread.length, 8);

      // What was checked and opened is kept in the email chat on the
      // server, so a fresh start shows it before Nexus answers again.
      final checked = await again.check('inbox');
      expect(checked.map((e) => e.id), ['m1', 'm2']);
      await again.openAndKeep(checked.first);
      final later = EmailAgent(client, model: model, options: const {});
      expect((await later.kept('inbox')).map((e) => e.subject), [
        'Field trip forms',
        'Your statement',
      ]);
      final kept = await later.keptOpen(checked.first);
      expect(kept?.suggestedReply, startsWith('Hi Ana'));
      expect(kept?.messages.single.body, contains('field trip forms'));
      expect(await later.keptOpen(checked.last), isNull);
      await client.deleteChat(id);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('a check adds to the kept emails and never drops them', () {
    Email e(String id, int day, {String note = ''}) =>
        Email(id: id, date: DateTime.utc(2026, 10, day), note: note);
    final kept = [e('b', 20), e('a', 10, note: 'old')];
    final merged = mergeEmails([e('c', 27), e('a', 10, note: 'new')], kept);
    expect(merged.map((m) => m.id), ['c', 'b', 'a']);
    expect(merged.last.note, 'new');
    expect(mergeEmails([e('x', 1)], kept, max: 2).map((m) => m.id), ['b', 'a']);
    final round = Email.fromJson(kept.first.toJson());
    expect(round.date, kept.first.date!.toLocal());
  });

  test('answers are read even with words around the JSON', () {
    expect(answerJson('Sure!\n```json\n[{"id": 1}]\n```'), [
      {'id': 1},
    ]);
    expect(answerJson('no json here'), isNull);
  });
}
