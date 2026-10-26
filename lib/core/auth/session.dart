import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../features/auth/sso_login_screen.dart' show clearBrowserCookies;
import '../api/openwebui_client.dart';

/// Server URL plus token (JWT from sign-in, or an `sk-` API key), and the
/// browser cookies from an SSO sign-in when a login gate sits in front.
class Session {
  const Session({
    required this.serverUrl,
    required this.token,
    this.cookie,
    this.user,
  });
  final String serverUrl;
  final String token;
  final String? cookie;
  final Map<String, dynamic>? user;

  String get userName => user?['name'] as String? ?? '';

  OpenWebUiClient client() =>
      OpenWebUiClient(baseUrl: serverUrl, token: token, cookie: cookie);
}

const _storage = FlutterSecureStorage();
const _kUrl = 'server_url';
const _kToken = 'token';
const _kCookie = 'cookie';

class SessionNotifier extends AsyncNotifier<Session?> {
  /// False only while the saved session is first being restored.
  bool booted = false;

  @override
  Future<Session?> build() async {
    try {
      return await _restore();
    } finally {
      booted = true;
    }
  }

  Future<Session?> _restore() async {
    final url = await _storage.read(key: _kUrl);
    final token = await _storage.read(key: _kToken);
    if (url == null || token == null) return null;
    final saved = Session(
      serverUrl: url,
      token: token,
      cookie: await _storage.read(key: _kCookie),
    );
    try {
      return Session(
        serverUrl: saved.serverUrl,
        token: saved.token,
        cookie: saved.cookie,
        user: await saved.client().me(),
      );
    } on ApiException catch (e) {
      // Token rejected, or a login gate's session expired (it redirects).
      if (e.statusCode == 401 || e.statusCode == 403 || e.redirectTo != null) {
        await _storage.delete(key: _kToken);
        return null;
      }
      // Server error: keep the session so the UI can still load.
      return saved;
    } catch (_) {
      // Server unreachable: same.
      return saved;
    }
  }

  Future<void> signInWithPassword(String url, String email, String password) =>
      _signIn(url, (c) => c.signIn(email, password));

  Future<void> signInWithApiKey(String url, String apiKey) =>
      _signIn(url, (c) async => c.token = apiKey.trim());

  /// Finishes an in-app browser (SSO) sign-in. [baseUrl] is used as given:
  /// discovery can't see past a login gate before the user has signed in.
  Future<void> signInWithBrowser(
    String baseUrl,
    String token,
    String? cookie,
  ) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final client = OpenWebUiClient(
        baseUrl: baseUrl,
        token: token,
        cookie: cookie,
      );
      return _save(client, await client.me());
    });
  }

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
      return _save(client, await client.me());
    });
  }

  Future<Session> _save(
    OpenWebUiClient client,
    Map<String, dynamic> user,
  ) async {
    await _storage.write(key: _kUrl, value: client.baseUrl);
    await _storage.write(key: _kToken, value: client.token);
    if (client.cookie == null) {
      await _storage.delete(key: _kCookie);
    } else {
      await _storage.write(key: _kCookie, value: client.cookie);
    }
    return Session(
      serverUrl: client.baseUrl,
      token: client.token!,
      cookie: client.cookie,
      user: user,
    );
  }

  Future<void> signOut() async {
    await clearBrowserCookies();
    await _storage.delete(key: _kToken);
    await _storage.delete(key: _kCookie);
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
  return session.client();
});
