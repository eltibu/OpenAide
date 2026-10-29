// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/chat/chat_controller.dart'
    show pickDefaultModel;
import 'package:nexus_assistant/features/studio/listen.dart';
import 'package:nexus_assistant/features/studio/office.dart';
import 'package:nexus_assistant/features/studio/sheet.dart';
import 'package:nexus_assistant/features/studio/slides.dart';
import 'package:nexus_assistant/features/studio/studio_api.dart';
import 'package:nexus_assistant/features/studio/studio_doc.dart';
import 'package:nexus_assistant/features/studio/studio_export.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('documents keep their text and versions on the server', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final api = StudioApi(client);

    final doc = await api.create('Studio test', '## Uno\n\nHola');
    try {
      var got = await api.get(doc.id);
      expect(got.markdown, '## Uno\n\nHola');
      expect(got.versions.single.label, 'Created');

      final sections = splitSections(got.markdown)
        ..add(Section(heading: 'Dos', body: 'Adiós'));
      final versions = [
        ...got.versions,
        Version(
          markdown: joinSections(sections),
          title: 'Studio test 2',
          at: DateTime.now(),
          label: 'AI: add a part',
        ),
      ];
      await api.save(
        doc.id,
        title: 'Studio test 2',
        markdown: joinSections(sections),
        versions: versions,
      );
      got = await api.get(doc.id);
      expect(got.title, 'Studio test 2');
      expect(got.markdown, '## Uno\n\nHola\n\n## Dos\n\nAdiós');
      expect(got.versions.map((v) => v.label), ['Created', 'AI: add a part']);

      // Saving text alone leaves the versions as they were.
      await api.save(doc.id, title: 'Studio test 2', markdown: 'changed');
      got = await api.get(doc.id);
      expect(got.versions, hasLength(2));

      // The web's note editor shows the same text.
      final raw = await client.send('GET', '/api/v1/notes/${doc.id}') as Map;
      expect(raw['data']['content']['html'], contains('changed'));
      expect(raw['data']['content']['json'], isNull);

      expect((await api.list()).any((d) => d.id == doc.id), isTrue);

      // The AI writes a draft with the prompt the Studio uses.
      final model = (await client.models()).first.id;
      final text = await client
          .streamCompletion(
            model: model,
            messages: generatePrompt(kind: 'Letter', about: 'a thank you'),
          )
          .join();
      expect(text, isNotEmpty);
    } finally {
      await api.delete(doc.id);
    }
    expect((await api.list()).any((d) => d.id == doc.id), isFalse);
  }, skip: skip);

  test('Excel, PowerPoint and Word files open as Studio files', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final api = StudioApi(client);
    final files = {
      'Budget.xlsx': toXlsx([
        Sheet(
          name: 'Costs',
          rows: [
            ['Item', 'Cost'],
            ['Paper', '3'],
            ['Total', '=SUM(B2:B2)'],
          ],
        ),
      ]),
      'Talk.pptx': toPptx('Talk', [
        Slide(title: 'Talk', body: 'Joel'),
        Slide(title: 'Why', body: '- Because', notes: 'Smile'),
      ]),
      'Letter.docx': toDocx('Letter', '## Hello\n\n- one\n- two'),
    };
    final ids = <String>[];
    try {
      for (final e in files.entries) {
        final (title, markdown) = importFile(e.key, e.value);
        ids.add((await api.create(title, markdown)).id);
      }
      final docs = [for (final id in ids) await api.get(id)];
      expect(docs.map((d) => studioKind(d.markdown)), [
        'sheet',
        'slides',
        'doc',
      ]);
      expect(
        sheetsFromMarkdown(docs[0].markdown).single.cell(2, 1),
        '=SUM(B2:B2)',
      );
      expect(slidesFromMarkdown(docs[1].markdown)[1].notes, 'Smile');
      expect(docs[2].title, 'Letter');
      expect(docs[2].markdown, contains('## Hello'));
      // The library sees what kind each one is from its list entry.
      final listed = {for (final d in await api.list()) d.id: d};
      expect(studioKind(listed[ids[0]]!.markdown), 'sheet');

      // The AI's spreadsheet answer reads back as sheets.
      final model = (await client.models()).first.id;
      final text = await client
          .streamCompletion(
            model: model,
            messages: sheetEditPrompt(
              title: 'Budget',
              markdown: docs[0].markdown,
              instruction: 'add a row',
            ),
          )
          .join();
      expect(text, isNotEmpty);
    } finally {
      for (final id in ids) {
        await api.delete(id);
      }
    }
  }, skip: skip);

  test('speech is turned into text by the server', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    // A second of a tone; the test server's speech to text answers
    // with fixed words when it is set up for it.
    final pcm = <int>[
      for (var i = 0; i < micRate; i++) ...[0x10, i.isEven ? 0x20 : 0xE0],
    ];
    try {
      final text = await transcribe(client, wavFile(pcm), 'speech.wav');
      expect(text, isNotEmpty);
    } on Object catch (e) {
      // A server without speech to text set up says so plainly.
      expect('$e', contains('ranscrib'));
    }
  }, skip: skip);

  test('your default model is kept in your settings', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final models = await client.models();
    final before = await client.userSettings();
    try {
      await client.send(
        'POST',
        '/api/v1/users/user/settings/update',
        body: {
          'ui': {
            'models': [models.last.id],
          },
        },
      );
      final settings = await client.userSettings();
      expect(
        pickDefaultModel(models, settings, await client.config()),
        models.last.id,
      );
    } finally {
      final ui = before['ui'];
      await client.send(
        'POST',
        '/api/v1/users/user/settings/update',
        body: {
          'ui': {'models': ui is Map ? ui['models'] : null},
        },
      );
    }
  }, skip: skip);
}
