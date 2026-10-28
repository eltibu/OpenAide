import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Where CI publishes builds: a pre-release per dev build, and a normal
/// release per public (stable) build.
const updateRepo = 'eltibu/Nexus-assistant';
const _kToken = 'github_update_token';
const _kChannel = 'update_channel';

/// The APK in a release: `nexus-assistant.apk` (dev builds, the name older
/// apps look for) or `OpenAide-<version>.apk` (public releases).
bool isAppAsset(String? name) =>
    name == 'nexus-assistant.apk' ||
    RegExp(r'^OpenAide[-\w.]*\.apk$').hasMatch(name ?? '');

/// Read-only token baked in at build time from the repo secret
/// NEXUS_UPDATE_TOKEN while the repo is private, so updates work without
/// typing anything. Public builds have none and read releases without one.
/// A token pasted in App updates takes precedence.
const builtInToken = String.fromEnvironment('NEXUS_UPDATE_TOKEN');

/// Stable gets public releases only; dev also gets every dev build
/// (GitHub pre-releases).
enum UpdateChannel { stable, dev }

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

/// The highest-numbered published release that has the app's APK. Dev
/// builds are pre-releases, left out unless [includeDev].
AvailableUpdate? newestRelease(
  List<dynamic> releases, {
  bool includeDev = true,
}) {
  AvailableUpdate? best;
  for (final r in releases.whereType<Map>()) {
    if (r['draft'] == true) continue;
    if (r['prerelease'] == true && !includeDev) continue;
    final build = buildFromTag(r['tag_name'] as String?);
    final asset = (r['assets'] as List? ?? [])
        .whereType<Map>()
        .where((a) => isAppAsset(a['name'] as String?))
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

  /// The saved channel. The first time, dev builds (those with a built-in or
  /// pasted token) pick dev and keep it, so the phone stays on dev builds
  /// after the token goes away; everyone else gets stable.
  Future<UpdateChannel> channel() async {
    final saved = await _storage.read(key: _kChannel);
    for (final c in UpdateChannel.values) {
      if (c.name == saved) return c;
    }
    final c = await token() != null ? UpdateChannel.dev : UpdateChannel.stable;
    await _storage.write(key: _kChannel, value: c.name);
    return c;
  }

  Future<void> setChannel(UpdateChannel c) async {
    await _storage.write(key: _kChannel, value: c.name);
    state = const UpdateIdle();
  }

  Map<String, String> _headers(String? token) => {
    if (token != null) 'Authorization': 'Bearer $token',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  /// Sends [req] with the token, if any. A public repo needs none, so when
  /// GitHub refuses an expired or revoked token, it tries once without.
  Future<http.StreamedResponse> _send(
    http.Client client,
    http.BaseRequest Function() req,
    String? token,
  ) async {
    final first = req()..headers.addAll(_headers(token));
    final res = await client.send(first);
    if (token == null || res.statusCode != 401) return res;
    await res.stream.drain<void>();
    return client.send(req()..headers.addAll(_headers(null)));
  }

  /// Looks for a newer build. Quiet on errors when [quiet] is true, as on
  /// app start.
  Future<void> check({bool quiet = false}) async {
    final token = await this.token();
    final channel = await this.channel();
    state = const UpdateChecking();
    final client = http.Client();
    try {
      final info = await PackageInfo.fromPlatform();
      final current = int.tryParse(info.buildNumber) ?? 0;
      final res = await http.Response.fromStream(
        await _send(
          client,
          // Stable: the public release GitHub marks latest. Dev: several
          // builds can finish out of order, so "latest" isn't always the
          // newest: look at recent releases and take the highest.
          () => http.Request(
            'GET',
            Uri.parse(
              channel == UpdateChannel.stable
                  ? 'https://api.github.com/repos/$updateRepo/releases/latest'
                  : 'https://api.github.com/repos/$updateRepo/releases?per_page=30',
            ),
          )..headers['Accept'] = 'application/vnd.github+json',
          token,
        ),
      );
      // No public release yet.
      if (channel == UpdateChannel.stable &&
          res.statusCode == 404 &&
          token == null) {
        state = UpToDate(current);
        return;
      }
      // A private repo answers 404 to anyone who can't read it, so 404 is an
      // access problem, never "up to date".
      if (res.statusCode == 401 ||
          res.statusCode == 403 ||
          res.statusCode == 404) {
        throw HttpException(
          token == null
              ? 'GitHub would not show the releases (${res.statusCode}). '
                    'Try again later.'
              : 'GitHub refused the token. Check that it can read this repo.',
        );
      }
      if (res.statusCode != 200) {
        throw HttpException('GitHub answered ${res.statusCode}.');
      }
      final body = jsonDecode(res.body);
      final newest = newestRelease(
        body is List ? body : [body],
        includeDev: channel == UpdateChannel.dev,
      );
      if (newest == null || newest.build <= current) {
        state = UpToDate(current);
        return;
      }
      state = UpdateFound(newest);
    } catch (e) {
      state = quiet ? const UpdateIdle() : UpdateFailed(_message(e));
    } finally {
      client.close();
    }
  }

  /// Downloads [update] and opens Android's installer.
  Future<void> install(AvailableUpdate update) async {
    final token = await this.token();
    state = const UpdateDownloading(null);
    final client = http.Client();
    try {
      // The asset API answers with a redirect to a short-lived download link
      // that must be fetched without the token.
      var res = await _send(
        client,
        () => http.Request('GET', Uri.parse(update.assetApiUrl))
          ..headers['Accept'] = 'application/octet-stream'
          ..followRedirects = false,
        token,
      );
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
