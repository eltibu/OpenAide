/// GitHub Copilot with the person's own plan (experimental): they sign in
/// to GitHub with a device code, and the app trades that sign-in for a
/// short-lived Copilot token. GitHub documents this for its Copilot SDK
/// but not as a plain API, so it may change without notice.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../oauth_clients.dart';
import 'ai_providers.dart' show AiException;

const _defaultApi = 'https://api.githubcopilot.com';

/// Headers Copilot's chat endpoints expect from a client.
Map<String, String> copilotHeaders(String token) => {
  'Authorization': 'Bearer $token',
  'Editor-Version': 'NexusAssistant/1.0',
  'Copilot-Integration-Id': 'nexus-assistant',
  'User-Agent': 'NexusAssistant',
};

class CopilotSession {
  const CopilotSession(this.base, this.token, this.expires);
  final String base;
  final String token;
  final DateTime expires;
}

final _sessions = <String, CopilotSession>{};

/// A Copilot token for [githubToken], reused until shortly before it
/// expires. When GitHub won't hand one out, the sign-in itself is tried
/// on the Copilot API.
Future<CopilotSession> copilotSession(
  String githubToken,
  http.Client client,
) async {
  final cached = _sessions[githubToken];
  if (cached != null &&
      cached.expires.isAfter(DateTime.now().add(const Duration(minutes: 2)))) {
    return cached;
  }
  final res = await client
      .get(
        Uri.parse('https://api.github.com/copilot_internal/v2/token'),
        headers: {
          'Authorization': 'token $githubToken',
          'Accept': 'application/json',
          'User-Agent': 'NexusAssistant',
        },
      )
      .timeout(const Duration(seconds: 20));
  if (res.statusCode == 401) {
    throw AiException('GitHub sign-in expired. Sign in to Copilot again.');
  }
  if (res.statusCode == 200) {
    final json = jsonDecode(res.body) as Map;
    final api = (json['endpoints'] as Map?)?['api'] as String?;
    final expires = (json['expires_at'] as num?)?.toInt();
    final session = CopilotSession(
      api ?? _defaultApi,
      '${json['token']}',
      expires == null
          ? DateTime.now().add(const Duration(minutes: 20))
          : DateTime.fromMillisecondsSinceEpoch(expires * 1000),
    );
    return _sessions[githubToken] = session;
  }
  if (res.statusCode == 403 && res.body.contains('copilot')) {
    throw AiException(
      "This GitHub account doesn't have a Copilot plan, or its "
      "organization doesn't allow Copilot in other apps.",
    );
  }
  // No exchange for this app: the GitHub token goes to Copilot directly.
  return _sessions[githubToken] = CopilotSession(
    _defaultApi,
    githubToken,
    DateTime.now().add(const Duration(days: 365)),
  );
}

/// Forget the Copilot token so the next request asks for a fresh one.
void dropCopilotSession(String githubToken) => _sessions.remove(githubToken);

/// The code the person types at github.com/login/device.
class DeviceCode {
  const DeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.interval,
    required this.expiresIn,
  });
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int interval;
  final int expiresIn;
}

bool get copilotSignInAvailable => githubClientId.isNotEmpty;

Future<DeviceCode> startGitHubDeviceSignIn({http.Client? httpClient}) async {
  if (!copilotSignInAvailable) {
    throw AiException("Copilot sign-in isn't set up in this build yet.");
  }
  final client = httpClient ?? http.Client();
  try {
    final res = await client
        .post(
          Uri.parse('https://github.com/login/device/code'),
          headers: {'Accept': 'application/json'},
          body: {'client_id': githubClientId, 'scope': 'read:user'},
        )
        .timeout(const Duration(seconds: 20));
    final json = jsonDecode(res.body) as Map;
    if (res.statusCode >= 400 || json['device_code'] == null) {
      throw AiException(
        '${json['error_description'] ?? json['error'] ?? 'GitHub answered ${res.statusCode}'}',
      );
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

/// Waits for the person to enter [code] on GitHub; returns their token.
/// Stops early once [cancelled] completes.
Future<String> waitForGitHubSignIn(
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
            Uri.parse('https://github.com/login/oauth/access_token'),
            headers: {'Accept': 'application/json'},
            body: {
              'client_id': githubClientId,
              'device_code': code.deviceCode,
              'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
            },
          )
          .timeout(const Duration(seconds: 20));
      final json = jsonDecode(res.body) as Map;
      final token = json['access_token'];
      if (token is String && token.isNotEmpty) return token;
      switch (json['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval = (json['interval'] as num?)?.toInt() ?? interval + 5;
          continue;
        case 'access_denied':
          throw AiException('GitHub sign-in was cancelled.');
        case 'expired_token':
          throw AiException('The code expired. Try again.');
        default:
          throw AiException(
            '${json['error_description'] ?? json['error'] ?? 'GitHub sign-in failed'}',
          );
      }
    }
    throw AiException(
      stop ? 'GitHub sign-in was cancelled.' : 'The code expired. Try again.',
    );
  } finally {
    if (httpClient == null) client.close();
  }
}

Duration _seconds(int s) => Duration(seconds: s);
