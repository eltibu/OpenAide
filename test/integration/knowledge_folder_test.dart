// Runs against a real Open WebUI server; see server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/phone_folder.dart';
import 'package:nexus_assistant/features/workspace/knowledge_api.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test(
    'uploads a folder, then syncs it after changes',
    () async {
      final client = OpenWebUiClient(baseUrl: url!);
      await client.signIn(email!, password!);
      final api = KnowledgeApi(client);
      final k = await api.create('nexus folder kb', 'test');
      final tmp = await Directory.systemTemp.createTemp('kb');
      final root = await Directory('${tmp.path}/Recipes').create();
      try {
        await File('${root.path}/soup.txt').writeAsString('Tomato soup.');
        await Directory('${root.path}/cakes').create();
        await File('${root.path}/cakes/carrot.txt')
            .writeAsString('Carrot cake.');
        await File('${root.path}/.hidden').writeAsString('skip me');

        final files = await readFolder(await folderOnDisk(root));
        expect(files.map((f) => '${f.path}/${f.filename}').toSet(), {
          'Recipes/soup.txt',
          'Recipes/cakes/carrot.txt',
        });

        var r = await api.addFolder(
          k.id,
          await folderOnDisk(root),
          sync: false,
        );
        expect((r.added, r.failed), (2, 0));
        var l = await api.files(k.id);
        expect(l.folders.map((f) => f.name), ['Recipes']);

        r = await api.addFolder(k.id, await folderOnDisk(root), sync: true);
        expect((r.unchanged, r.added, r.deleted), (2, 0, 0));

        await File('${root.path}/soup.txt').writeAsString('Pea soup.');
        await File('${root.path}/cakes/carrot.txt').delete();
        r = await api.addFolder(k.id, await folderOnDisk(root), sync: true);
        expect((r.modified, r.deleted, r.failed), (1, 1, 0));
        l = await api.files(k.id, folderId: l.folders.single.id);
        expect(l.files.map((f) => f.name), ['soup.txt']);
        expect(l.folders, isEmpty);
      } finally {
        await tmp.delete(recursive: true);
        await api.delete(k.id);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
