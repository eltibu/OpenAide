/// Saved copies of what the app last read from the server (your chats,
/// folders, notes, models and settings), so they still open with no
/// connection. The server stays the only real copy: a saved one is only
/// used when the server can't be reached, and is replaced by the next read.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Where saved copies live; a folder on the phone, or memory in tests.
abstract class OfflineStore {
  Future<void> put(String key, String body);
  Future<String?> get(String key);
  Future<void> clear();
}

/// True while what's on screen came from saved copies.
final offlineNotice = ValueNotifier<bool>(false);

/// The reads worth keeping for offline use: chat lists, chats, folders,
/// notes, models, the server's config, you and your settings.
bool offlineCacheable(String path) => _cacheable.any((p) => p.hasMatch(path));

final _cacheable = [
  RegExp(r'^/api/config$'),
  RegExp(r'^/api/models$'),
  RegExp(r'^/api/v1/auths/$'),
  RegExp(r'^/api/v1/users/user/settings$'),
  RegExp(r'^/api/v1/chats/$'),
  RegExp(r'^/api/v1/chats/pinned$'),
  RegExp(r'^/api/v1/chats/folder/[^/]+(/list)?$'),
  RegExp(r'^/api/v1/chats/[0-9a-fA-F-]{8,}$'),
  RegExp(r'^/api/v1/folders/$'),
  RegExp(r'^/api/v1/notes/$'),
  RegExp(r'^/api/v1/notes/[0-9a-fA-F-]{8,}$'),
];

/// One key per address and query, so each page of a list is its own.
String offlineKey(String path, Map<String, String>? query) {
  if (query == null || query.isEmpty) return path;
  final keys = query.keys.toList()..sort();
  return '$path?${keys.map((k) => '$k=${query[k]}').join('&')}';
}

/// Saved copies in a folder on the phone, one file each; the oldest chats
/// go once there are more than [keep].
class FileOfflineStore implements OfflineStore {
  FileOfflineStore(this.dir, {this.keep = 150});
  final Directory dir;
  final int keep;
  int _writes = 0;

  File _file(String key) =>
      File('${dir.path}/${base64Url.encode(utf8.encode(key))}.json');

  @override
  Future<void> put(String key, String body) async {
    try {
      await dir.create(recursive: true);
      await _file(key).writeAsString(body, flush: true);
      if (++_writes % 20 == 0) await _prune();
    } catch (_) {
      // A full phone only loses the saved copy.
    }
  }

  @override
  Future<String?> get(String key) async {
    try {
      final f = _file(key);
      return await f.exists() ? await f.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> clear() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _prune() async {
    final files = (await dir.list().toList()).whereType<File>().toList();
    if (files.length <= keep) return;
    final dated = [for (final f in files) (f, (await f.stat()).modified)]
      ..sort((a, b) => a.$2.compareTo(b.$2));
    for (final (f, _) in dated.take(files.length - keep)) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }
}

/// Saved copies in memory, for tests.
class MemoryOfflineStore implements OfflineStore {
  final values = <String, String>{};

  @override
  Future<void> put(String key, String body) async => values[key] = body;

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> clear() async => values.clear();
}

/// A thin strip over the app while saved copies are showing.
class OfflineStrip extends StatelessWidget {
  const OfflineStrip({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: offlineNotice,
    builder: (context, offline, _) => Column(
      children: [
        if (offline) const _Strip(),
        Expanded(
          // The strip already sits below the status bar.
          child: MediaQuery.removePadding(
            context: context,
            removeTop: offline,
            child: child,
          ),
        ),
      ],
    ),
  );
}

class _Strip extends StatelessWidget {
  const _Strip();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Icon(
                Icons.cloud_off,
                size: 16,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Can't reach the server: showing saved copies.",
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSecondaryContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
