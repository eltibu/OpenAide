/// Share to Open WebUI Community: as the web, the item goes to the
/// community site's upload page (openwebui.com), where you sign in there
/// and publish it. The web opens that page in a new tab and hands the item
/// over once it says "loaded"; here the page opens in the app and gets it
/// the same way.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/i18n/app_strings.dart';

const communityUrl = 'https://openwebui.com';

/// The script that hands [payload] to the community page: it stands in for
/// the web's opener tab, answering the page's "loaded" with the item.
String communityHandOver(String payload) {
  final item = jsonEncode(payload);
  return '''
(function () {
  if (window.__openaideShare) return;
  var sent = false;
  function send() {
    if (sent) return;
    sent = true;
    window.postMessage($item, '*');
  }
  window.__openaideShare = send;
  try {
    Object.defineProperty(window, 'opener', {
      configurable: true,
      value: { postMessage: function (m) { if (m === 'loaded') setTimeout(send, 0); } }
    });
  } catch (e) {}
})();
''';
}

/// Opens the community page at [path] (such as "/functions/create" or
/// "/chats/upload") and hands it [payload], a JSON string.
Future<void> shareToCommunity(
  BuildContext context, {
  required String path,
  required String payload,
}) => Navigator.push(
  context,
  MaterialPageRoute<void>(
    builder: (_) => _CommunityPage(path: path, payload: payload),
  ),
);

class _CommunityPage extends StatefulWidget {
  const _CommunityPage({required this.path, required this.payload});
  final String path;
  final String payload;

  @override
  State<_CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<_CommunityPage> {
  late final WebViewController _web;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    final script = communityHandOver(widget.payload);
    final site = Uri.parse(communityUrl).host;
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          // Early, so the page finds its "opener"; and again once loaded,
          // in case it asked before the stand-in was there.
          onPageStarted: (_) => _web.runJavaScript(script),
          onPageFinished: (url) async {
            if (Uri.tryParse(url)?.host != site) return;
            await _web.runJavaScript(script);
            await _web.runJavaScript(
              'setTimeout(function () { window.__openaideShare && '
              'window.__openaideShare(); }, 1500);',
            );
          },
          // Community pages and its sign-in stay here; other links open
          // the browser.
          onNavigationRequest: (r) {
            final to = Uri.tryParse(r.url);
            if (to == null || !to.scheme.startsWith('http')) {
              return NavigationDecision.navigate;
            }
            if (to.host == site || to.host.endsWith('.$site')) {
              return NavigationDecision.navigate;
            }
            // Signing in with another account goes through its own pages.
            if (to.path.contains('oauth') || to.path.contains('login')) {
              return NavigationDecision.navigate;
            }
            launchUrl(to, mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(Uri.parse('$communityUrl${widget.path}'));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const T('Open WebUI Community'),
      leading: IconButton(
        tooltip: tr('Close'),
        icon: const Icon(Icons.close),
        onPressed: () => Navigator.pop(context),
      ),
      bottom: _progress < 100
          ? PreferredSize(
              preferredSize: const Size.fromHeight(2),
              child: LinearProgressIndicator(
                value: _progress / 100,
                minHeight: 2,
              ),
            )
          : null,
    ),
    body: WebViewWidget(controller: _web),
  );
}

/// What the web sends for a chat: the chat itself and the models it used.
String chatCommunityPayload(Map chat, List<Map> models) {
  final used = {...?(chat['models'] as List?)?.map((m) => '$m')};
  return jsonEncode({
    'chat': chat,
    'models': [
      for (final m in models)
        if (used.contains('${m['id']}')) m,
    ],
  });
}

/// Whether the server lets people share to the community.
bool communitySharingOn(Map? config) =>
    (config?['features'] as Map?)?['enable_community_sharing'] == true;

/// A tool's or function's "Support" link (its manifest's funding_url), as
/// the web's heart button; null when it has none.
String? fundingUrl(Map? item) {
  final url = (((item?['meta'] as Map?)?['manifest'] as Map?)?['funding_url'])
      ?.toString()
      .trim();
  return url == null || url.isEmpty ? null : url;
}

/// The heart: opens the author's support page in the browser.
class SupportButton extends StatelessWidget {
  const SupportButton({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tr('Support'),
    icon: const Icon(Icons.favorite_border),
    onPressed: () =>
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
  );
}
