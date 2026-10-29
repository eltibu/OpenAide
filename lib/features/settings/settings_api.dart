import '../../core/api/openwebui_client.dart';
import '../../core/models/chat.dart';
import '../notes/notes_api.dart' show fromServerTime;

/// Something the server remembers about the person, as on the web's
/// Personalization > Memory.
class Memory {
  const Memory({
    required this.id,
    required this.content,
    required this.updated,
    this.path,
  });

  factory Memory.fromJson(Map j) => Memory(
    id: '${j['id']}',
    content: '${j['content'] ?? ''}',
    path: j['path'] as String?,
    updated: fromServerTime((j['updated_at'] ?? j['created_at'] ?? 0) as num),
  );

  final String id;
  final String content;
  final String? path;
  final DateTime updated;
}

/// The person's own settings and account, kept on the server like the web's
/// Settings window, so a change shows on every device.
class SettingsApi {
  SettingsApi(this.client);
  final OpenWebUiClient client;

  /// The `ui` settings, raw (without the site's defaults mixed in).
  Future<Map<String, dynamic>> ui() async {
    final res = await client.send(
      'GET',
      '/api/v1/users/user/settings',
      query: {'raw': 'true'},
    );
    return ((res as Map?)?['ui'] as Map?)?.cast<String, dynamic>() ?? {};
  }

  /// Changes only the given `ui` fields; null resets one to the default.
  Future<void> patchUi(Map<String, dynamic> fields) => client.send(
    'POST',
    '/api/v1/users/user/settings/update',
    body: {'ui': fields},
  );

  Future<Map<String, dynamic>> me() => client.me();

  /// Saves the profile. Gender and birth date go every time, since the
  /// server clears what isn't sent.
  Future<void> updateProfile({
    required String name,
    required String imageUrl,
    String? bio,
    String? gender,
    String? dateOfBirth,
  }) => client.send(
    'POST',
    '/api/v1/auths/update/profile',
    body: {
      'name': name,
      'profile_image_url': imageUrl,
      'bio': ?bio,
      'gender': (gender ?? '').isEmpty ? null : gender,
      'date_of_birth': (dateOfBirth ?? '').isEmpty ? null : dateOfBirth,
    },
  );

  /// Changes your password; [current] must be right.
  Future<void> updatePassword(String current, String next) => client.send(
    'POST',
    '/api/v1/auths/update/password',
    body: {'password': current, 'new_password': next},
  );

  /// Your API key, or null when you have none.
  Future<String?> apiKey() async {
    try {
      final res = await client.send('GET', '/api/v1/auths/api_key') as Map?;
      return res?['api_key'] as String?;
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<String> createApiKey() async =>
      '${(await client.send('POST', '/api/v1/auths/api_key') as Map)['api_key']}';

  Future<void> deleteApiKey() => client.send('DELETE', '/api/v1/auths/api_key');

  /// Your status (emoji and message) others see. The server keeps what
  /// isn't sent, so clearing sends empty text.
  Future<void> setStatus({String emoji = '', String message = ''}) =>
      client.send(
        'POST',
        '/api/v1/users/user/status/update',
        body: {'status_emoji': emoji, 'status_message': message},
      );

  // ---- Memory ----

  Future<List<Memory>> memories() async => [
    for (final m
        in ((await client.send('GET', '/api/v1/memories/')) as List? ??
                const [])
            .whereType<Map>())
      Memory.fromJson(m),
  ]..sort((a, b) => b.updated.compareTo(a.updated));

  Future<void> addMemory(String content) =>
      client.send('POST', '/api/v1/memories/add', body: {'content': content});

  Future<void> updateMemory(String id, String content) => client.send(
    'POST',
    '/api/v1/memories/${Uri.encodeComponent(id)}/update',
    body: {'content': content},
  );

  Future<void> deleteMemory(String id) =>
      client.send('DELETE', '/api/v1/memories/${Uri.encodeComponent(id)}');

  Future<void> clearMemories() =>
      client.send('DELETE', '/api/v1/memories/delete/user');

  // ---- Chats ----

  Future<List<ChatSummary>> archived() async {
    final out = <ChatSummary>[];
    for (var page = 1; page < 50; page++) {
      final res =
          await client.send(
            'GET',
            '/api/v1/chats/archived',
            query: {'page': '$page'},
          ) as List? ??
          const [];
      out.addAll([
        for (final c in res.whereType<Map>())
          ChatSummary.fromJson(c.cast<String, dynamic>()),
      ]);
      if (res.length < 60) break;
    }
    return out;
  }

  Future<void> archiveAll() => client.send('POST', '/api/v1/chats/archive/all');

  Future<void> unarchiveAll() =>
      client.send('POST', '/api/v1/chats/unarchive/all');

  Future<void> deleteAllChats() => client.send('DELETE', '/api/v1/chats/');
}
