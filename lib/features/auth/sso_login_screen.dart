import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// What an in-app browser sign-in produced.
class SsoResult {
  const SsoResult({required this.token, this.cookie});

  /// Open WebUI's JWT, taken from the web app's localStorage.
  final String token;

  /// Every cookie the browser holds for the server, so requests also pass
  /// a login gate in front of Open WebUI (portal, Cloudflare Access...).
  final String? cookie;
}

const _cookies = MethodChannel('nexus/cookies');

/// Opens the server in a WebView so the user signs in exactly as in a
/// browser: through any proxy login page, then Open WebUI's own SSO or
/// password form. Pops with an [SsoResult] once Open WebUI holds a token.
class SsoLoginScreen extends StatefulWidget {
  const SsoLoginScreen({super.key, required this.baseUrl});
  final String baseUrl;

  @override
  State<SsoLoginScreen> createState() => _SsoLoginScreenState();
}

class _SsoLoginScreenState extends State<SsoLoginScreen> {
  late final WebViewController _web;
  bool _loading = true;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: (_) {
            setState(() => _loading = false);
            _checkSignedIn();
          },
          onUrlChange: (_) => _checkSignedIn(),
        ),
      )
      ..loadRequest(Uri.parse('${widget.baseUrl}/auth'));
  }

  Future<void> _checkSignedIn() async {
    if (_done) return;
    final raw = await _web.runJavaScriptReturningResult(
      "localStorage.getItem('token') || ''",
    );
    final token = '$raw'.replaceAll('"', '');
    if (token.isEmpty || token == 'null' || _done) return;
    _done = true;
    String? cookie;
    try {
      cookie = await _cookies.invokeMethod<String>('get', {
        'url': widget.baseUrl,
      });
    } on PlatformException {
      cookie = null;
    }
    if (mounted) {
      Navigator.pop(context, SsoResult(token: token, cookie: cookie));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in'),
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: WebViewWidget(controller: _web),
    );
  }
}

/// Clears the in-app browser's cookies on sign-out.
Future<void> clearBrowserCookies() async {
  try {
    await _cookies.invokeMethod('clear');
  } on PlatformException {
    // Nothing to clear on platforms without the channel.
  } on MissingPluginException {
    // Same, e.g. in tests.
  }
}
