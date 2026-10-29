/// A folder picked on the phone, with every file in it: Upload Folder in
/// Files and the knowledge base's Upload or Sync directory.
///
/// On Android this is the system's own folder picker, which can open any
/// folder the person chooses (Download, Documents, a USB stick, a cloud
/// drive), not only ones an app may read by path.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PhoneFile {
  const PhoneFile(this.path, this.size, this.read);

  /// Where it sits under the picked folder: folder names and its own name,
  /// joined with /.
  final String path;
  final int size;
  final Future<List<int>> Function() read;

  String get name => path.split('/').last;

  /// Its folders under the picked folder, joined with /; empty at the top.
  String get folder {
    final cut = path.lastIndexOf('/');
    return cut < 0 ? '' : path.substring(0, cut);
  }
}

class PhoneFolder {
  const PhoneFolder(this.name, this.files);
  final String name;
  final List<PhoneFile> files;
}

const _channel = MethodChannel('nexus/folders');

/// Asks for a folder; null when none was picked. [android] stands in for
/// the platform in tests.
Future<PhoneFolder?> pickPhoneFolder({@visibleForTesting bool? android}) async {
  if (android ?? (!kIsWeb && Platform.isAndroid)) {
    final picked = await _channel.invokeMapMethod<String, Object?>('pick');
    if (picked == null) return null;
    return PhoneFolder('${picked['name']}', [
      for (final f in picked['files'] as List? ?? const [])
        if (f is Map)
          PhoneFile(
            '${f['path']}',
            (f['size'] as num?)?.toInt() ?? 0,
            () async =>
                await _channel.invokeMethod<Uint8List>('read', {
                  'uri': f['uri'],
                }) ??
                Uint8List(0),
          ),
    ]);
  }
  final path = await FilePicker.getDirectoryPath();
  return path == null ? null : folderOnDisk(Directory(path));
}

/// Every file in [root] and its folders, skipping hidden ones.
Future<PhoneFolder> folderOnDisk(Directory root) async {
  final name = root.uri.pathSegments.where((p) => p.isNotEmpty).last;
  final base = root.path.endsWith('/') ? root.path : '${root.path}/';
  final files = <PhoneFile>[];
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (e is! File || !e.path.startsWith(base)) continue;
    final rel = e.path.substring(base.length);
    if (rel.split('/').any((p) => p.startsWith('.'))) continue;
    files.add(PhoneFile(rel, await e.length(), e.readAsBytes));
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return PhoneFolder(name, files);
}
