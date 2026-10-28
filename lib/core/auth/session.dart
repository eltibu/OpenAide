import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../features/auth/sso_login_screen.dart' show clearBrowserCookies;
import '../api/chat_socket.dart';
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

  /// Sign-in with a directory (LDAP) account.
  Future<void> signInWithLdap(String url, String user, String password) =>
      _signIn(
        url,
        (c) async => c.authStep('/api/v1/auths/ldap', {
          'user': user,
          'password': password,
        }),
      );

  /// A new account (when the server allows sign-ups).
  Future<void> signUp(String url, String name, String email, String password) =>
      _signIn(
        url,
        (c) async => c.authStep('/api/v1/auths/signup', {
          'name': name,
          'email': email,
          'password': password,
        }),
      );

  /// Sends a two-step code (or a reset token) for [step]. Signs in when
  /// that's the last step; otherwise the state holds the next [SignInStep].
  Future<void> answerStep(
    SignInStep step,
    String code, {
    bool recovery = false,
  }) async {
    final path = switch (step.next) {
      'enroll' => '/api/v1/auths/mfa/enroll/confirm',
      'recover' => '/api/v1/auths/mfa/recover',
      _ => '/api/v1/auths/mfa/verify',
    };
    state = await AsyncValue.guard(() async {
      final client = step.client;
      final Map<String, dynamic> res;
      try {
        res = await client.authStep(path, {
          'challenge_token': step.challenge,
          if (step.next == 'recover')
            'reset_token': code
          else ...{
            'code': code,
            'recovery': recovery,
          },
        });
      } on SignInStep catch (next) {
        // A reset token leads to setting up a new authenticator.
        throw SignInStep(
          client,
          {...step.reply, ...next.reply}..remove('error'),
        );
      } catch (e) {
        // A wrong code: same step again, saying why.
        throw SignInStep(client, {...step.reply, 'error': '$e'});
      }
      // A new authenticator comes with recovery codes, shown once.
      if ((res['recovery_codes'] as List?)?.isNotEmpty == true) {
        throw SignInStep(client, {...res, 'next_step': 'codes'});
      }
      return _save(client, await client.me());
    });
  }

  /// After the recovery codes were seen: signed in.
  Future<void> finishStep(SignInStep step) async {
    state = await AsyncValue.guard(
      () async => _save(step.client, await step.client.me()),
    );
  }

  /// Looks again at a pending account, after an admin may have approved it.
  Future<void> recheck() async {
    final s = state.value;
    if (s == null) return;
    state = await AsyncValue.guard(
      () async => Session(
        serverUrl: s.serverUrl,
        token: s.token,
        cookie: s.cookie,
        user: await s.client().me(),
      ),
    );
  }

  /// Back to the sign-in form, dropping a half-done two-step sign-in.
  void restart() => state = const AsyncData(null);

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

/// One live connection per signed-in session, for streaming replies.
final chatSocketProvider = Provider<ChatSocket>((ref) {
  final session = ref.watch(sessionProvider).value;
  if (session == null) throw StateError('Not signed in');
  final socket = ChatSocket(
    baseUrl: session.serverUrl,
    token: session.token,
    cookie: session.cookie,
  );
  ref.onDispose(socket.dispose);
  return socket;
});
