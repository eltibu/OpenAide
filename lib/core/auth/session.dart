import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/openwebui_client.dart';

/// Server URL plus token (JWT from sign-in, or an `sk-` API key).
class Session {
  const Session({required this.serverUrl, required this.token, this.user});
  final String serverUrl;
  final String token;
  final Map<String, dynamic>? user;

  String get userName => user?['name'] as String? ?? '';
}

const _storage = FlutterSecureStorage();
const _kUrl = 'server_url';
const _kToken = 'token';

class SessionNotifier extends AsyncNotifier<Session?> {
  @override
  Future<Session?> build() async {
    final url = await _storage.read(key: _kUrl);
    final token = await _storage.read(key: _kToken);
    if (url == null || token == null) return null;
    try {
      final client = OpenWebUiClient(baseUrl: url, token: token);
      return Session(
        serverUrl: client.baseUrl,
        token: token,
        user: await client.me(),
      );
    } on ApiException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        await _storage.delete(key: _kToken);
        return null;
      }
      // Server unreachable: keep the session so cached UI can still load.
      return Session(serverUrl: url, token: token);
    } catch (_) {
      return Session(serverUrl: url, token: token);
    }
  }

  Future<void> signInWithPassword(String url, String email, String password) =>
      _signIn(url, (c) => c.signIn(email, password));

  Future<void> signInWithApiKey(String url, String apiKey) =>
      _signIn(url, (c) async => c.token = apiKey.trim());

  Future<void> _signIn(
    String url,
    Future<void> Function(OpenWebUiClient) auth,
  ) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final client = OpenWebUiClient(
        baseUrl: await OpenWebUiClient.discover(url),
      );
      await auth(client);
      final user = await client.me();
      await _storage.write(key: _kUrl, value: client.baseUrl);
      await _storage.write(key: _kToken, value: client.token);
      return Session(
        serverUrl: client.baseUrl,
        token: client.token!,
        user: user,
      );
    });
  }

  Future<void> signOut() async {
    await _storage.delete(key: _kToken);
    state = const AsyncData(null);
  }
}

final sessionProvider = AsyncNotifierProvider<SessionNotifier, Session?>(
  SessionNotifier.new,
);

/// API client for the current session. Throws if signed out.
final clientProvider = Provider<OpenWebUiClient>((ref) {
  final session = ref.watch(sessionProvider).value;
  if (session == null) throw StateError('Not signed in');
  return OpenWebUiClient(baseUrl: session.serverUrl, token: session.token);
});
