/// Your keys for AI providers (Settings > AI providers), kept in the
/// phone's keystore, and the models they unlock.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/ai/ai_providers.dart';
import '../../core/models/model_info.dart';

const _storage = FlutterSecureStorage();
String _keyName(AiProvider p) => 'ai_key_${p.id}';

class AiKeys extends AsyncNotifier<Map<AiProvider, String>> {
  @override
  Future<Map<AiProvider, String>> build() async {
    final out = <AiProvider, String>{};
    for (final p in AiProvider.values) {
      try {
        final key = await _storage.read(key: _keyName(p));
        if (key != null && key.isNotEmpty) out[p] = key;
      } catch (_) {
        // Keystore unreadable: that provider just isn't set up.
      }
    }
    return out;
  }

  /// Saves [key] for [p]; null or empty removes it.
  Future<void> set(AiProvider p, String? key) async {
    final trimmed = key?.trim() ?? '';
    if (trimmed.isEmpty) {
      await _storage.delete(key: _keyName(p));
    } else {
      await _storage.write(key: _keyName(p), value: trimmed);
    }
    final next = {...?state.value};
    if (trimmed.isEmpty) {
      next.remove(p);
    } else {
      next[p] = trimmed;
    }
    state = AsyncData(next);
  }
}

final aiKeysProvider = AsyncNotifierProvider<AiKeys, Map<AiProvider, String>>(
  AiKeys.new,
);

/// Models from every provider with a key. A provider that fails is left
/// out rather than hiding the others.
final providerModelsProvider = FutureProvider<List<ModelInfo>>((ref) async {
  final keys = await ref.watch(aiKeysProvider.future);
  final found = await Future.wait([
    for (final e in keys.entries)
      listProviderModels(e.key, e.value).catchError((_) => const <ModelInfo>[]),
  ]);
  return [for (final list in found) ...list];
});

/// A running "Sign in with OpenRouter": the browser is open, and the app
/// waits on the phone itself (localhost) for OpenRouter to send it back.
class OpenRouterSignIn {
  OpenRouterSignIn._(this._servers, this._verifier);

  final List<HttpServer> _servers;
  final String _verifier;
  final _done = Completer<String>();

  /// The key, once the person approves; an error if they refuse.
  Future<String> get key => _done.future;

  static Future<OpenRouterSignIn> start() async {
    final v4 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final servers = [v4];
    // "localhost" may resolve to ::1 in the browser.
    try {
      servers.add(await HttpServer.bind(InternetAddress.loopbackIPv6, v4.port));
    } catch (_) {}
    final sign = OpenRouterSignIn._(servers, newCodeVerifier(Random.secure()));
    for (final s in servers) {
      s.listen(sign._onRequest, onError: (_) {});
    }
    final url = openRouterAuthUrl(
      callback: 'http://localhost:${v4.port}/callback',
      verifier: sign._verifier,
    );
    if (!await launchUrl(url, mode: LaunchMode.inAppBrowserView) &&
        !await launchUrl(url, mode: LaunchMode.externalApplication)) {
      sign.cancel();
      throw AiException("Couldn't open the browser.");
    }
    // Codes last 10 minutes; past that, give up.
    Future.delayed(const Duration(minutes: 10), () {
      if (!sign._done.isCompleted) {
        sign._finish(error: AiException('Sign-in took too long. Try again.'));
      }
    });
    return sign;
  }

  Future<void> _onRequest(HttpRequest req) async {
    if (req.uri.path != '/callback' || _done.isCompleted) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final code = req.uri.queryParameters['code'];
    String? error;
    String? key;
    if (code == null || code.isEmpty) {
      error = 'OpenRouter sign-in was cancelled.';
    } else {
      try {
        key = await exchangeOpenRouterCode(code, _verifier);
      } catch (e) {
        error = '$e';
      }
    }
    req.response.headers.contentType = ContentType.html;
    req.response.write(_page(error));
    await req.response.close();
    _finish(key: key, error: error == null ? null : AiException(error));
  }

  void _finish({String? key, Object? error}) {
    if (!_done.isCompleted) {
      if (key != null) {
        _done.complete(key);
      } else {
        _done.completeError(error ?? AiException('Sign-in failed.'));
      }
    }
    for (final s in _servers) {
      s.close(force: true);
    }
  }

  void cancel() => _finish(error: AiException('Sign-in was cancelled.'));

  /// What the browser shows afterwards, with a button back to the app.
  static String _page(String? error) {
    final title = error == null ? 'Signed in to OpenRouter' : 'Not signed in';
    final body = error == null
        ? 'Nexus has your OpenRouter key now. You can close this page.'
        : _escape(error);
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>$title</title><style>body{font-family:sans-serif;'
        'max-width:28rem;margin:4rem auto;padding:0 1.5rem;text-align:center}'
        'a{display:inline-block;margin-top:1.5rem;padding:.8rem 1.6rem;'
        'border-radius:2rem;background:#0d6e66;color:#fff;'
        'text-decoration:none}</style></head><body><h1>$title</h1>'
        '<p>$body</p><a href="intent://#Intent;'
        'package=com.nexus.nexus_assistant;end">Back to Nexus</a>'
        '</body></html>';
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
