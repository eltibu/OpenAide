import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// What the page may load. Scripts never run. Unless [remote], nothing is
/// fetched from the internet either: senders put tracking pixels in
/// pictures and styles, which tell them when and where an email was opened.
String emailPolicy({required bool remote}) => remote
    ? "default-src 'none'; img-src * data:; style-src * 'unsafe-inline'; "
          "font-src * data:; media-src * data:"
    : "default-src 'none'; img-src data:; style-src 'unsafe-inline'; "
          "font-src data:; media-src data:";

/// Whether [html] has pictures or styles from the internet.
bool hasRemoteContent(String html) => RegExp(
  r'''(src|background|href)\s*=\s*["']?\s*(https?:)?//|url\(\s*["']?\s*(https?:)?//''',
  caseSensitive: false,
).hasMatch(html.replaceAll(RegExp(r'<a\s[^>]*>', caseSensitive: false), ''));

/// [html] ready to show on a phone: fits the screen, pictures shrink to
/// the width, long words wrap. Internet content loads only when [remote].
String emailPage(String html, {bool remote = false}) =>
    '<!doctype html><html><head><meta charset="utf-8">'
    '<meta http-equiv="Content-Security-Policy" '
    'content="${emailPolicy(remote: remote)}">'
    '<meta name="viewport" content="width=device-width, initial-scale=1">'
    '<style>'
    'html,body{margin:0;padding:0;background:#fff;color:#202124}'
    'body{padding:12px;font-family:Roboto,sans-serif;font-size:15px;'
    'line-height:1.45;overflow-wrap:anywhere}'
    'img{max-width:100%!important;height:auto!important}'
    'table{max-width:100%!important}'
    'td,th{overflow-wrap:anywhere}'
    'pre{white-space:pre-wrap}'
    'blockquote{margin:0 0 0 8px;padding-left:8px;border-left:2px solid #ccc}'
    '</style></head><body>$html</body></html>';

/// An email laid out as its sender made it, like Gmail shows it. Scripts
/// don't run, links open in the browser, and pictures from the internet
/// load only after a tap.
class EmailHtml extends StatefulWidget {
  const EmailHtml(this.html, {super.key});
  final String html;

  @override
  State<EmailHtml> createState() => _EmailHtmlState();
}

class _EmailHtmlState extends State<EmailHtml> {
  late final bool _hasRemote = hasRemoteContent(widget.html);
  bool _remote = false;

  late final _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.disabled)
    ..setBackgroundColor(Colors.white)
    ..enableZoom(true)
    ..setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (r) {
          if (r.url.startsWith('about:') || r.url.startsWith('data:')) {
            return NavigationDecision.navigate;
          }
          final uri = Uri.tryParse(r.url);
          if (uri != null) {
            launchUrl(uri, mode: LaunchMode.externalApplication);
          }
          return NavigationDecision.prevent;
        },
      ),
    )
    ..loadHtmlString(emailPage(widget.html));

  void _showRemote() {
    setState(() => _remote = true);
    _web.loadHtmlString(emailPage(widget.html, remote: true));
  }

  @override
  Widget build(BuildContext context) {
    final web = WebViewWidget(controller: _web);
    if (!_hasRemote || _remote) return web;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    "Pictures from the internet are hidden, so the sender "
                    "can't see that you opened this.",
                  ),
                ),
                TextButton(
                  onPressed: _showRemote,
                  child: const Text('Show pictures'),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: web),
      ],
    );
  }
}
