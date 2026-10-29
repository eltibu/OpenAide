import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/phone_folder.dart';
import 'package:nexus_assistant/features/workspace/knowledge_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Android: the picked folder\'s files, read through the picker',
    () async {
      final reads = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('nexus/folders'), (
            call,
          ) async {
            if (call.method == 'pick') {
              return {
                'name': 'Trip',
                'files': [
                  {'path': 'notes.txt', 'uri': 'content://a/1', 'size': 2},
                  {
                    'path': 'photos/day1.txt',
                    'uri': 'content://a/2',
                    'size': 4,
                  },
                ],
              };
            }
            final uri = (call.arguments as Map)['uri'] as String;
            reads.add(uri);
            return Uint8List.fromList(
              utf8.encode(uri.endsWith('1') ? 'hi' : 'sun!'),
            );
          });
      final folder = (await pickPhoneFolder(android: true))!;
      expect(folder.name, 'Trip');
      expect(folder.files.map((f) => f.path), ['notes.txt', 'photos/day1.txt']);
      expect(folder.files[1].folder, 'photos');
      expect(folder.files[1].name, 'day1.txt');
      expect(reads, isEmpty);

      final listed = await readFolder(folder);
      expect(listed.map((f) => f.path), ['Trip', 'Trip/photos']);
      expect(utf8.decode(await listed[1].read()), 'sun!');
      expect(listed[1].size, 4);
    },
  );

  test('Android: nothing picked', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('nexus/folders'),
          (_) async => null,
        );
    expect(await pickPhoneFolder(android: true), isNull);
  });

  test('a folder on disk skips hidden files and folders', () async {
    final root = await Directory.systemTemp.createTemp('Project');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/a.txt').writeAsString('a');
    await Directory('${root.path}/sub').create();
    await File('${root.path}/sub/b.txt').writeAsString('bb');
    await File('${root.path}/.secret').writeAsString('x');
    await Directory('${root.path}/.git').create();
    await File('${root.path}/.git/c').writeAsString('x');
    final folder = await folderOnDisk(root);
    expect(folder.files.map((f) => f.path), ['a.txt', 'sub/b.txt']);
    expect(folder.files[1].size, 2);
  });
}
