import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Where CI publishes builds (a GitHub Release per build on the main branch).
const updateRepo = 'eltibu/Nexus-assistant';
const _assetName = 'nexus-assistant.apk';
const _kToken = 'github_update_token';

/// Read-only token baked in at build time from the repo secret
/// NEXUS_UPDATE_TOKEN, so updates work without typing anything, even after a
/// reinstall. A token pasted in App updates takes precedence.
const builtInToken = String.fromEnvironment('NEXUS_UPDATE_TOKEN');

const _storage = FlutterSecureStorage();
const _channel = MethodChannel('nexus/updates');

class AvailableUpdate {
  const AvailableUpdate({
    required this.build,
    required this.assetApiUrl,
    required this.notes,
  });
  final int build;
  final String assetApiUrl;
  final String notes;
}

sealed class UpdateState {
  const UpdateState();
}

class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

class UpToDate extends UpdateState {
  const UpToDate(this.build);
  final int build;
}

class UpdateFound extends UpdateState {
  const UpdateFound(this.update);
  final AvailableUpdate update;
}

class UpdateDownloading extends UpdateState {
  const UpdateDownloading(this.progress);

  /// 0..1, or null when the size is unknown.
  final double? progress;
}

class UpdateFailed extends UpdateState {
  const UpdateFailed(this.message);
  final String message;
}

/// The build number in a release tag: `v0.1.123` (current) or `build-123`
/// (older builds) give 123. Version codes only ever go up, so this is what
/// decides whether a release is newer.
int? buildFromTag(String? tag) {
  final m = RegExp(r'^(?:v0\.1\.|build-)(\d+)$').firstMatch(tag ?? '');
  return m == null ? null : int.parse(m.group(1)!);
}

/// The highest-numbered published release that has the app's APK.
AvailableUpdate? newestRelease(List<dynamic> releases) {
  AvailableUpdate? best;
  for (final r in releases.whereType<Map>()) {
    if (r['draft'] == true) continue;
    final build = buildFromTag(r['tag_name'] as String?);
    final asset = (r['assets'] as List? ?? [])
        .whereType<Map>()
        .where((a) => a['name'] == _assetName)
        .firstOrNull;
    if (build == null || asset == null) continue;
    if (best == null || build > best.build) {
      best = AvailableUpdate(
        build: build,
        assetApiUrl: asset['url'] as String,
        notes: (r['body'] as String? ?? '').trim(),
      );
    }
  }
  return best;
}

/// How a build is shown to people: `0.1.<build>`.
String versionName(int build) => '0.1.$build';

class Updater extends Notifier<UpdateState> {
  @override
  UpdateState build() => const UpdateIdle();

  Future<String?> token() async {
    final saved = await _storage.read(key: _kToken);
    if (saved != null && saved.isNotEmpty) return saved;
    return builtInToken.isEmpty ? null : builtInToken;
  }

  Future<void> setToken(String value) async {
    final t = value.trim();
    if (t.isEmpty) {
      await _storage.delete(key: _kToken);
    } else {
      await _storage.write(key: _kToken, value: t);
    }
  }

  Map<String, String> _headers(String token) => {
    'Authorization': 'Bearer $token',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  /// Looks for a newer build. Quiet when no token is set and [quiet] is true,
  /// as on app start.
  Future<void> check({bool quiet = false}) async {
    final token = await this.token();
    if (token == null) {
      if (!quiet) {
        state = const UpdateFailed(
          'Add a GitHub token in App updates to check for new builds.',
        );
      }
      return;
    }
    state = const UpdateChecking();
    try {
      final info = await PackageInfo.fromPlatform();
      final current = int.tryParse(info.buildNumber) ?? 0;
      final res = await http.get(
        // Several builds can finish out of order, so GitHub's "latest" isn't
        // always the newest: look at recent releases and take the highest.
        Uri.parse(
          'https://api.github.com/repos/$updateRepo/releases?per_page=20',
        ),
        headers: {..._headers(token), 'Accept': 'application/vnd.github+json'},
      );
      // A private repo answers 404 to a token that can't read it, so 404 is a
      // token problem, never "up to date".
      if (res.statusCode == 401 ||
          res.statusCode == 403 ||
          res.statusCode == 404) {
        throw const HttpException(
          'GitHub refused the token. Check that it can read this repo.',
        );
      }
      if (res.statusCode != 200) {
        throw HttpException('GitHub answered ${res.statusCode}.');
      }
      final newest = newestRelease(jsonDecode(res.body) as List);
      if (newest == null || newest.build <= current) {
        state = UpToDate(current);
        return;
      }
      state = UpdateFound(newest);
    } catch (e) {
      state = quiet ? const UpdateIdle() : UpdateFailed(_message(e));
    }
  }

  /// Downloads [update] and opens Android's installer.
  Future<void> install(AvailableUpdate update) async {
    final token = await this.token();
    if (token == null) {
      state = const UpdateFailed('Add a GitHub token in App updates first.');
      return;
    }
    state = const UpdateDownloading(null);
    final client = http.Client();
    try {
      // The asset API answers with a redirect to a short-lived download link
      // that must be fetched without the token.
      final req = http.Request('GET', Uri.parse(update.assetApiUrl))
        ..headers.addAll({
          ..._headers(token),
          'Accept': 'application/octet-stream',
        })
        ..followRedirects = false;
      var res = await client.send(req);
      final location = res.headers['location'];
      if (res.isRedirect && location != null) {
        await res.stream.drain<void>();
        res = await client.send(http.Request('GET', Uri.parse(location)));
      }
      if (res.statusCode != 200) {
        throw HttpException('Download failed (${res.statusCode}).');
      }

      final path = await _channel.invokeMethod<String>('apkPath');
      final file = File(path!);
      final sink = file.openWrite();
      final total = res.contentLength;
      var received = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) {
          state = UpdateDownloading(received / total);
        }
      }
      await sink.close();

      final outcome = await _channel.invokeMethod<String>('install');
      state = outcome == 'permission'
          ? const UpdateFailed(
              'Allow "Install unknown apps" for OpenAide, then tap '
              'Install again.',
            )
          : outcome == 'started'
          ? UpdateFound(update)
          : UpdateFailed('Android could not open the installer: $outcome');
    } catch (e) {
      state = UpdateFailed(_message(e));
    } finally {
      client.close();
    }
  }

  String _message(Object e) => switch (e) {
    HttpException(:final message) => message,
    PlatformException(:final message, :final code) => message ?? code,
    SocketException() => 'No connection to GitHub. Check your internet.',
    _ => '$e',
  };
}

final updaterProvider = NotifierProvider<Updater, UpdateState>(Updater.new);
