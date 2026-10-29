/// Signing in to Gmail and Outlook with the provider's own sign-in (OAuth)
/// instead of a password, for mail over IMAP and SMTP.
///
/// Microsoft uses a device code (the person types a code at
/// microsoft.com/link), so nothing has to come back into the app. Google
/// doesn't allow mail in that flow, so its page comes back to a listener on
/// the phone itself (127.0.0.1), as for desktop mail apps.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/ai/copilot.dart' show DeviceCode;
import '../../core/oauth_clients.dart';
import '../../core/store.dart';

enum MailSignIn {
  google('google', 'Google'),
  microsoft('microsoft', 'Microsoft');

  const MailSignIn(this.id, this.label);
  final String id;
  final String label;

  static MailSignIn? byId(String? id) =>
      MailSignIn.values.where((s) => s.id == id).firstOrNull;

  bool get available => switch (this) {
    google => googleClientId.isNotEmpty && googleClientSecret.isNotEmpty,
    microsoft => microsoftClientId.isNotEmpty,
  };
}

class MailSignInError implements Exception {
  const MailSignInError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A finished sign-in: whose mail it opens, and the long-lived token that
/// gets fresh access tokens.
class MailGrant {
  const MailGrant(
    this.email,
    this.name,
    this.refreshToken,
    this.accessToken,
    this.expires,
  );
  final String email;
  final String name;
  final String refreshToken;
  final String accessToken;
  final DateTime expires;
}

const _msBase = 'https://login.microsoftonline.com/common/oauth2/v2.0';
const _msScopes =
    'offline_access openid email profile '
    'https://outlook.office.com/IMAP.AccessAsUser.All '
    'https://outlook.office.com/SMTP.Send';
const _googleScopes = 'https://mail.google.com/ openid email profile';

// Microsoft: device code.

Future<DeviceCode> startMicrosoftSignIn({http.Client? httpClient}) async {
  if (!MailSignIn.microsoft.available) {
    throw const MailSignInError(
      "Microsoft sign-in isn't set up in this version yet.",
    );
  }
  final client = httpClient ?? http.Client();
  try {
    final res = await client
        .post(
          Uri.parse('$_msBase/devicecode'),
          body: {'client_id': microsoftClientId, 'scope': _msScopes},
        )
        .timeout(const Duration(seconds: 20));
    final json = _json(res.body);
    if (res.statusCode >= 400 || json['device_code'] == null) {
      throw MailSignInError(_errorOf(json, res.statusCode));
    }
    return DeviceCode(
      deviceCode: '${json['device_code']}',
      userCode: '${json['user_code']}',
      verificationUri: '${json['verification_uri']}',
      interval: (json['interval'] as num?)?.toInt() ?? 5,
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 900,
    );
  } finally {
    if (httpClient == null) client.close();
  }
}

/// Waits for the person to enter [code] at Microsoft. Stops once
/// [cancelled] completes.
Future<MailGrant> waitForMicrosoftSignIn(
  DeviceCode code, {
  Future<void>? cancelled,
  http.Client? httpClient,
  Duration Function(int seconds) delay = _seconds,
}) async {
  final client = httpClient ?? http.Client();
  var stop = false;
  unawaited(cancelled?.then((_) => stop = true));
  var interval = code.interval;
  final deadline = DateTime.now().add(Duration(seconds: code.expiresIn));
  try {
    while (!stop && DateTime.now().isBefore(deadline)) {
      await Future.delayed(delay(interval));
      if (stop) break;
      final res = await client
          .post(
            Uri.parse('$_msBase/token'),
            body: {
              'client_id': microsoftClientId,
              'device_code': code.deviceCode,
              'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
            },
          )
          .timeout(const Duration(seconds: 20));
      final json = _json(res.body);
      if (json['access_token'] is String) return _grant(json);
      switch (json['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += 5;
          continue;
        case 'authorization_declined':
          throw const MailSignInError('Microsoft sign-in was cancelled.');
        case 'expired_token':
          throw const MailSignInError('The code expired. Try again.');
        default:
          throw MailSignInError(_errorOf(json, res.statusCode));
      }
    }
    throw MailSignInError(
      stop
          ? 'Microsoft sign-in was cancelled.'
          : 'The code expired. Try again.',
    );
  } finally {
    if (httpClient == null) client.close();
  }
}

// Google: browser, back to a listener on the phone.

/// A running "Sign in with Google": the browser is open and the app waits
/// on 127.0.0.1 for Google to send it back.
class GoogleSignIn {
  GoogleSignIn._(this._server, this._verifier, this._state, this._redirect);

  final HttpServer _server;
  final String _verifier;
  final String _state;
  final String _redirect;
  final _done = Completer<MailGrant>();

  Future<MailGrant> get grant => _done.future;

  static Future<GoogleSignIn> start({String? loginHint}) async {
    if (!MailSignIn.google.available) {
      throw const MailSignInError(
        "Google sign-in isn't set up in this version yet.",
      );
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final sign = GoogleSignIn._(
      server,
      _randomText(random),
      _randomText(random),
      'http://127.0.0.1:${server.port}',
    );
    server.listen(sign._onRequest, onError: (_) {});
    final url = googleAuthUrl(
      redirect: sign._redirect,
      verifier: sign._verifier,
      state: sign._state,
      loginHint: loginHint,
    );
    if (!await launchUrl(url, mode: LaunchMode.inAppBrowserView) &&
        !await launchUrl(url, mode: LaunchMode.externalApplication)) {
      sign.cancel();
      throw const MailSignInError("Couldn't open the browser.");
    }
    Future.delayed(const Duration(minutes: 10), () {
      sign._finish(
        error: const MailSignInError('Sign-in took too long. Try again.'),
      );
    });
    return sign;
  }

  Future<void> _onRequest(HttpRequest req) async {
    final q = req.uri.queryParameters;
    // Only Google's redirect for this sign-in, not another app guessing
    // the port.
    if (req.uri.path != '/' || q['state'] != _state || _done.isCompleted) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final code = q['code'];
    MailGrant? grant;
    Object? error;
    if (code == null || code.isEmpty) {
      error = const MailSignInError('Google sign-in was cancelled.');
    } else {
      try {
        grant = await exchangeGoogleCode(code, _verifier, _redirect);
      } catch (e) {
        error = e;
      }
    }
    req.response.headers.contentType = ContentType.html;
    req.response.write(_page(error == null ? null : '$error'));
    await req.response.close();
    _finish(grant: grant, error: error);
  }

  void _finish({MailGrant? grant, Object? error}) {
    if (!_done.isCompleted) {
      if (grant != null) {
        _done.complete(grant);
      } else {
        _done.completeError(error ?? const MailSignInError('Sign-in failed.'));
      }
    }
    _server.close(force: true);
  }

  void cancel() =>
      _finish(error: const MailSignInError('Sign-in was cancelled.'));

  static String _page(String? error) {
    final title = error == null ? 'Signed in to Google' : 'Not signed in';
    final body = error == null
        ? 'OpenAide can read and send your Gmail now. You can close this page.'
        : const HtmlEscape().convert(error);
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>$title</title><style>body{font-family:sans-serif;'
        'max-width:28rem;margin:4rem auto;padding:0 1.5rem;text-align:center}'
        'a{display:inline-block;margin-top:1.5rem;padding:.8rem 1.6rem;'
        'border-radius:2rem;background:#0d6e66;color:#fff;'
        'text-decoration:none}</style></head><body><h1>$title</h1>'
        '<p>$body</p><a href="intent://#Intent;'
        'package=$appPackage;end">Back to OpenAide</a>'
        '</body></html>';
  }
}

Uri googleAuthUrl({
  required String redirect,
  required String verifier,
  required String state,
  String? loginHint,
}) => Uri.parse('https://accounts.google.com/o/oauth2/v2/auth').replace(
  queryParameters: {
    'client_id': googleClientId,
    'redirect_uri': redirect,
    'response_type': 'code',
    'scope': _googleScopes,
    'code_challenge': _challenge(verifier),
    'code_challenge_method': 'S256',
    'access_type': 'offline',
    'prompt': 'consent',
    'state': state,
    if (loginHint != null && loginHint.isNotEmpty) 'login_hint': loginHint,
  },
);

Future<MailGrant> exchangeGoogleCode(
  String code,
  String verifier,
  String redirect, {
  http.Client? httpClient,
}) async {
  final client = httpClient ?? http.Client();
  try {
    final res = await client
        .post(
          Uri.parse('https://oauth2.googleapis.com/token'),
          body: {
            'code': code,
            'code_verifier': verifier,
            'client_id': googleClientId,
            // A desktop client's secret isn't secret (Google says so for
            // installed apps); Google still asks for it.
            'client_secret': googleClientSecret,
            'redirect_uri': redirect,
            'grant_type': 'authorization_code',
          },
        )
        .timeout(const Duration(seconds: 20));
    final json = _json(res.body);
    if (res.statusCode >= 400 || json['access_token'] is! String) {
      throw MailSignInError(_errorOf(json, res.statusCode));
    }
    return _grant(json);
  } finally {
    if (httpClient == null) client.close();
  }
}

// Access tokens for signed-in accounts.

const _storage = FlutterSecureStorage();
final _cache = <String, ({String token, DateTime expires})>{};

String _rotatedKey(String email) => 'mail_oauth_${email.toLowerCase()}';

/// Keeps the newest refresh token for [email]. Microsoft hands out a new
/// one with each refresh, and the old ones run out.
Future<void> keepRefreshToken(String email, String token) async {
  try {
    await _storage.write(key: _rotatedKey(email), value: token);
  } catch (_) {}
}

Future<void> forgetMailSignIn(String email) async {
  _cache.remove(email.toLowerCase());
  try {
    await _storage.delete(key: _rotatedKey(email));
  } catch (_) {}
}

/// Seeds the cache with a sign-in's first access token.
void rememberAccessToken(MailGrant g) =>
    _cache[g.email.toLowerCase()] = (token: g.accessToken, expires: g.expires);

/// A current access token for a signed-in account, refreshed when it's
/// about to run out.
Future<String> mailAccessToken(
  MailSignIn provider,
  String email,
  String savedRefreshToken, {
  http.Client? httpClient,
}) async {
  final key = email.toLowerCase();
  final cached = _cache[key];
  if (cached != null &&
      cached.expires.isAfter(DateTime.now().add(const Duration(minutes: 2)))) {
    return cached.token;
  }
  String refresh = savedRefreshToken;
  try {
    refresh = await _storage.read(key: _rotatedKey(email)) ?? refresh;
  } catch (_) {}
  final client = httpClient ?? http.Client();
  try {
    final res = await client
        .post(
          Uri.parse(switch (provider) {
            MailSignIn.google => 'https://oauth2.googleapis.com/token',
            MailSignIn.microsoft => '$_msBase/token',
          }),
          body: {
            'grant_type': 'refresh_token',
            'refresh_token': refresh,
            'client_id': switch (provider) {
              MailSignIn.google => googleClientId,
              MailSignIn.microsoft => microsoftClientId,
            },
            if (provider == MailSignIn.google)
              'client_secret': googleClientSecret,
            if (provider == MailSignIn.microsoft) 'scope': _msScopes,
          },
        )
        .timeout(const Duration(seconds: 20));
    final json = _json(res.body);
    final token = json['access_token'];
    if (res.statusCode >= 400 || token is! String) {
      if (json['error'] == 'invalid_grant') {
        throw MailSignInError(
          'The ${provider.label} sign-in for $email ran out. Sign in again '
          'in Settings > Accounts.',
        );
      }
      throw MailSignInError(_errorOf(json, res.statusCode));
    }
    final next = json['refresh_token'];
    if (next is String && next.isNotEmpty && next != refresh) {
      await keepRefreshToken(email, next);
    }
    final expires = DateTime.now().add(
      Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 3600),
    );
    _cache[key] = (token: token, expires: expires);
    return token;
  } finally {
    if (httpClient == null) client.close();
  }
}

// Helpers.

MailGrant _grant(Map json) {
  final claims = idTokenClaims('${json['id_token'] ?? ''}');
  final email = '${claims['email'] ?? claims['preferred_username'] ?? ''}'
      .trim();
  if (!email.contains('@')) {
    throw const MailSignInError("The sign-in didn't say which address it is.");
  }
  final refresh = json['refresh_token'];
  if (refresh is! String || refresh.isEmpty) {
    throw const MailSignInError(
      "The sign-in didn't allow staying signed in. Try again.",
    );
  }
  return MailGrant(
    email,
    '${claims['name'] ?? ''}',
    refresh,
    '${json['access_token']}',
    DateTime.now().add(
      Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 3600),
    ),
  );
}

/// The claims in an id token (who signed in). Only read, not verified:
/// it came straight from the provider over TLS.
Map<String, dynamic> idTokenClaims(String idToken) {
  final parts = idToken.split('.');
  if (parts.length < 2) return const {};
  try {
    final json = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    return json is Map<String, dynamic> ? json : const {};
  } catch (_) {
    return const {};
  }
}

Map _json(String body) {
  try {
    final j = jsonDecode(body);
    return j is Map ? j : const {};
  } catch (_) {
    return const {};
  }
}

String _errorOf(Map json, int status) =>
    '${json['error_description'] ?? json['error'] ?? 'The sign-in answered $status'}';

String _randomText(Random r) =>
    base64UrlEncode([for (var i = 0; i < 32; i++) r.nextInt(256)])
        .replaceAll('=', '');

String _challenge(String verifier) =>
    base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');

Duration _seconds(int s) => Duration(seconds: s);
