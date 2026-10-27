import '../../core/api/openwebui_client.dart';
import '../notes/notes_api.dart' show fromServerTime;

class AdminUser {
  AdminUser(this.json);
  final Map<String, dynamic> json;

  String get id => '${json['id']}';
  String get name => '${json['name'] ?? ''}';
  String get email => '${json['email'] ?? ''}';
  String get role => '${json['role'] ?? 'pending'}';
  DateTime get lastActive =>
      fromServerTime((json['last_active_at'] as num?) ?? 0);
  DateTime get created => fromServerTime((json['created_at'] as num?) ?? 0);
}

/// A server function: a filter, pipe or action written in Python.
class ServerFunction {
  ServerFunction(this.json);
  final Map<String, dynamic> json;

  String get id => '${json['id']}';
  String get name => '${json['name'] ?? id}';
  String get type => '${json['type'] ?? ''}';
  bool get active => json['is_active'] == true;
  bool get global => json['is_global'] == true;
  String get description => '${(json['meta'] as Map?)?['description'] ?? ''}';
}

/// The roles a user can have.
const userRoles = ['pending', 'user', 'admin'];

/// The site switches the Admin Panel's General page shows, with what they do.
const adminSwitches = <(String, String, String)>[
  ('ENABLE_SIGNUP', 'New sign-ups', 'Let people make their own accounts'),
  ('ENABLE_LOGIN_FORM', 'Login form', 'Show email and password sign-in'),
  ('ENABLE_API_KEYS', 'API keys', 'Let people make API keys'),
  ('ENABLE_COMMUNITY_SHARING', 'Community sharing', 'Share to the community'),
  ('ENABLE_MESSAGE_RATING', 'Message rating', 'Thumbs up and down on replies'),
  ('ENABLE_FOLDERS', 'Folders', 'Chat folders'),
  ('ENABLE_CHANNELS', 'Channels', 'Group chats with people and models'),
  ('ENABLE_NOTES', 'Notes', ''),
  ('ENABLE_CALENDAR', 'Calendar', ''),
  ('ENABLE_AUTOMATIONS', 'Automations', 'Scheduled prompts'),
  ('ENABLE_MEMORIES', 'Memories', 'Models remember things about people'),
  ('ENABLE_USER_STATUS', 'User status', 'People can set a status'),
  ('ENABLE_USER_WEBHOOKS', 'User webhooks', 'Notifications to a webhook'),
  ('SHOW_ADMIN_DETAILS', 'Show admin contact', 'On the pending-account page'),
];

class AdminApi {
  AdminApi(this.client);
  final OpenWebUiClient client;

  // ---- Users ----

  Future<List<AdminUser>> users({String query = ''}) async {
    final out = <AdminUser>[];
    for (var page = 1; page < 50; page++) {
      final res = await client.send(
        'GET',
        '/api/v1/users/',
        query: {'page': '$page', if (query.isNotEmpty) 'query': query},
      ) as Map;
      final items = (res['users'] as List? ?? const []).whereType<Map>();
      out.addAll(items.map((u) => AdminUser(u.cast<String, dynamic>())));
      if (items.isEmpty || out.length >= ((res['total'] as num?) ?? 0)) break;
    }
    return out;
  }

  Future<void> addUser({
    required String name,
    required String email,
    required String password,
    required String role,
  }) => client.send(
    'POST',
    '/api/v1/auths/add',
    body: {'name': name, 'email': email, 'password': password, 'role': role},
  );

  /// Changes only what's given; a password is set only when not empty.
  Future<void> updateUser(
    String id, {
    String? name,
    String? email,
    String? role,
    String? password,
  }) => client.send(
    'POST',
    '/api/v1/users/${Uri.encodeComponent(id)}/update',
    body: {
      'name': ?name,
      'email': ?email,
      'role': ?role,
      if (password != null && password.isNotEmpty) 'password': password,
    },
  );

  Future<void> deleteUser(String id) =>
      client.send('DELETE', '/api/v1/users/${Uri.encodeComponent(id)}');

  // ---- Site settings ----

  Future<Map<String, dynamic>> config() async =>
      ((await client.send('GET', '/api/v1/auths/admin/config')) as Map)
          .cast<String, dynamic>();

  /// Saves the whole form back, as the web does, so untouched settings keep
  /// their values.
  Future<Map<String, dynamic>> saveConfig(Map<String, dynamic> config) async =>
      ((await client.send(
        'POST',
        '/api/v1/auths/admin/config',
        body: config,
      )) as Map).cast<String, dynamic>();

  // ---- Functions ----

  Future<List<ServerFunction>> functions() async => [
    for (final f
        in ((await client.send('GET', '/api/v1/functions/')) as List? ??
                const [])
            .whereType<Map>())
      ServerFunction(f.cast<String, dynamic>()),
  ];

  Future<void> toggleFunction(String id) => client.send(
    'POST',
    '/api/v1/functions/id/${Uri.encodeComponent(id)}/toggle',
  );

  Future<void> toggleFunctionGlobal(String id) => client.send(
    'POST',
    '/api/v1/functions/id/${Uri.encodeComponent(id)}/toggle/global',
  );

  Future<void> deleteFunction(String id) => client.send(
    'DELETE',
    '/api/v1/functions/id/${Uri.encodeComponent(id)}/delete',
  );
}
