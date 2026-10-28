import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// [html] ready to show on a phone: fits the screen, pictures shrink to
/// the width, long words wrap.
String emailPage(String html) =>
    '<!doctype html><html><head><meta charset="utf-8">'
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
/// don't run, and links open in the browser.
class EmailHtml extends StatefulWidget {
  const EmailHtml(this.html, {super.key});
  final String html;

  @override
  State<EmailHtml> createState() => _EmailHtmlState();
}

class _EmailHtmlState extends State<EmailHtml> {
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

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _web);
}
