// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/studio/studio_api.dart';
import 'package:nexus_assistant/features/studio/studio_doc.dart';

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
}
