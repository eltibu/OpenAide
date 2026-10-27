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

  Future<void> updateProfile({
    required String name,
    required String imageUrl,
    String? bio,
  }) => client.send(
    'POST',
    '/api/v1/auths/update/profile',
    body: {'name': name, 'profile_image_url': imageUrl, 'bio': ?bio},
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

/// The model settings a person can set for all their chats (the web's
/// Settings > General > Advanced Parameters), with what each one means.
/// Left empty, the model's own value is used.
const chatParams = <(String, String, String)>[
  ('temperature', 'Temperature', 'Higher is more creative, lower more exact'),
  ('max_tokens', 'Max tokens', 'Longest a reply can be'),
  ('top_p', 'Top P', 'Keeps only the likeliest words adding up to this'),
  ('top_k', 'Top K', 'Picks from this many likeliest words'),
  ('min_p', 'Min P', 'Drops words much less likely than the best'),
  ('frequency_penalty', 'Frequency penalty', 'Discourages repeating words'),
  ('presence_penalty', 'Presence penalty', 'Encourages new topics'),
  ('seed', 'Seed', 'Same seed, same reply'),
  ('reasoning_effort', 'Reasoning effort', 'low, medium or high'),
];

/// A typed value as the web stores it: a number when it is one.
Object? paramValue(String key, String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  if (key == 'reasoning_effort') return t;
  return int.tryParse(t) ?? double.tryParse(t) ?? t;
}
