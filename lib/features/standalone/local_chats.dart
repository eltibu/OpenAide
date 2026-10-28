/// Using Nexus without a server: the switch that picks it, and chats kept
/// on the phone in Open WebUI's own shape (so they could move to a server
/// later).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models/chat.dart';

const _storage = FlutterSecureStorage();
const _kStandalone = 'standalone_mode';
const _kModel = 'standalone_model';

/// True when the person chose to use Nexus with AI providers only.
class StandaloneMode extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    try {
      return await _storage.read(key: _kStandalone) == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> set(bool on) async {
    if (on) {
      await _storage.write(key: _kStandalone, value: '1');
    } else {
      await _storage.delete(key: _kStandalone);
    }
    state = AsyncData(on);
  }
}

final standaloneModeProvider = AsyncNotifierProvider<StandaloneMode, bool>(
  StandaloneMode.new,
);

/// The model last used without a server, for the next new chat.
Future<String?> lastStandaloneModel() async {
  try {
    return await _storage.read(key: _kModel);
  } catch (_) {
    return null;
  }
}

Future<void> saveStandaloneModel(String id) async {
  try {
    await _storage.write(key: _kModel, value: id);
  } catch (_) {}
}

/// One JSON file per chat in the app's private folder.
class LocalChatStore {
  LocalChatStore(this.dir);
  final Directory dir;

  static Future<LocalChatStore> open() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/local_chats');
    await dir.create(recursive: true);
    return LocalChatStore(dir);
  }

  File _file(String id) => File('${dir.path}/$id.json');

  Future<List<ChatSummary>> list() async {
    final out = <ChatSummary>[];
    if (!await dir.exists()) return out;
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(await f.readAsString()) as Map;
        out.add(
          ChatSummary(
            id: '${json['id']}',
            title: '${json['title'] ?? 'New Chat'}',
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              ((json['updated_at'] as num?)?.toInt() ?? 0) * 1000,
            ),
          ),
        );
      } catch (_) {
        // A damaged file: skip it rather than losing the list.
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<Chat?> load(String id) async {
    final f = _file(id);
    if (!await f.exists()) return null;
    final json = (jsonDecode(await f.readAsString()) as Map)
        .cast<String, dynamic>();
    return Chat.fromServer({'id': json['id'], 'chat': json['chat']});
  }

  Future<void> save(Chat chat) async {
    final tmp = File('${_file(chat.id).path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'id': chat.id,
        'title': chat.title,
        'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'chat': chat.toServerBody(),
      }),
    );
    await tmp.rename(_file(chat.id).path);
  }

  Future<void> delete(String id) async {
    final f = _file(id);
    if (await f.exists()) await f.delete();
  }
}

final localChatStoreProvider = FutureProvider<LocalChatStore>(
  (ref) => LocalChatStore.open(),
);

final localChatsProvider = FutureProvider<List<ChatSummary>>((ref) async {
  final store = await ref.watch(localChatStoreProvider.future);
  return store.list();
});
