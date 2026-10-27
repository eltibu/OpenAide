import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/auth/session.dart';

/// One of the server's own pages (Notes, Workspace, Admin...) inside the
/// app, signed in as the user. A stand-in until each section is native:
/// it always matches the server, including features added later.
class ServerPage extends ConsumerStatefulWidget {
  const ServerPage({super.key, required this.title, this.path = '', this.url});
  final String title;

  /// Where on the server, such as `/notes`.
  final String path;

  /// Another site of the person's own instead (such as Rosanna's Lessons
  /// Studio): opened as it is, keeping its own sign-in.
  final String? url;

  @override
  ConsumerState<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends ConsumerState<ServerPage> {
  late final WebViewController _web;
  int _progress = 0;

  /// The first server page shown: back from here leaves, never deeper into
  /// the web app's own history.
  String? _start;

  @override
  void initState() {
    super.initState();
    final client = ref.read(clientProvider);
    final base = Uri.parse(widget.url ?? client.baseUrl);
    // A site behind a sign-in portal sends the person to its login page on
    // a sibling address (auth.example.com): those stay here too.
    final site = base.host.split('.').length > 2
        ? base.host.split('.').skip(base.host.split('.').length - 2).join('.')
        : base.host;
    bool ours(Uri to) =>
        to.host == base.host ||
        (widget.url != null && (to.host == site || to.host.endsWith('.$site')));
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageFinished: (url) {
            if (_start == null && Uri.tryParse(url)?.host == base.host) {
              _start = url;
            }
          },
          // The server's pages stay here; links elsewhere open the browser.
          onNavigationRequest: (r) {
            final to = Uri.tryParse(r.url);
            if (to == null ||
                to.scheme == 'about' ||
                to.scheme == 'data' ||
                ours(to)) {
              return NavigationDecision.navigate;
            }
            launchUrl(to, mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          },
        ),
      );
    if (widget.url != null) {
      _web.loadRequest(base);
    } else {
      _open(client.baseUrl, client.token, client.cookie, base);
    }
  }

  Future<void> _open(
    String baseUrl,
    String? token,
    String? cookie,
    Uri base,
  ) async {
    // Cookies from sign-in, so a login gate in front of the server lets the
    // page through, as it lets the app's own requests through.
    final jar = WebViewCookieManager();
    for (final part in (cookie ?? '').split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      await jar.setCookie(
        WebViewCookie(
          name: part.substring(0, eq).trim(),
          value: part.substring(eq + 1).trim(),
          domain: base.host,
        ),
      );
    }
    // Pages the server serves itself (a terminal's port preview) sign in
    // with the token cookie, as the web's own sign-in sets it.
    if (token != null && token.isNotEmpty) {
      await jar.setCookie(
        WebViewCookie(name: 'token', value: token, domain: base.host),
      );
    }
    // Open WebUI's web app keeps its sign-in in localStorage: put the app's
    // token there from a page on the same origin, then go to the section.
    final target = '$baseUrl${widget.path}';
    await _web.loadHtmlString(
      '<!DOCTYPE html><html><body><script>'
      'try{localStorage.setItem("token",${jsonEncode(token ?? '')});}catch(e){}'
      'location.replace(${jsonEncode(target)});'
      '</script></body></html>',
      baseUrl: '$baseUrl/',
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) async {
        if (popped) return;
        final at = await _web.currentUrl();
        if (_start != null &&
            at != null &&
            Uri.parse(at).path != Uri.parse(_start!).path &&
            await _web.canGoBack()) {
          await _web.goBack();
        } else if (context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          // Always straight back to the app, whatever the page did.
          leading: IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(widget.title),
          actions: [
            IconButton(
              tooltip: 'Reload',
              icon: const Icon(Icons.refresh),
              onPressed: _web.reload,
            ),
          ],
          bottom: _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    value: _progress == 0 ? null : _progress / 100,
                  ),
                )
              : null,
        ),
        body: SafeArea(top: false, child: WebViewWidget(controller: _web)),
      ),
    );
  }
}
