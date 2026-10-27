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
  const ServerPage({super.key, required this.title, required this.path});
  final String title;

  /// Where on the server, such as `/notes`.
  final String path;

  @override
  ConsumerState<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends ConsumerState<ServerPage> {
  late final WebViewController _web;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    final client = ref.read(clientProvider);
    final base = Uri.parse(client.baseUrl);
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          // The server's pages stay here; links elsewhere open the browser.
          onNavigationRequest: (r) {
            final to = Uri.tryParse(r.url);
            if (to == null ||
                to.scheme == 'about' ||
                to.scheme == 'data' ||
                to.host == base.host) {
              return NavigationDecision.navigate;
            }
            launchUrl(to, mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          },
        ),
      );
    _open(client.baseUrl, client.token, client.cookie, base);
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
        if (await _web.canGoBack()) {
          await _web.goBack();
        } else if (context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
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
