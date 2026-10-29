import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../core/auth/session.dart';

/// A tool's interactive result in a reply (a YouTube player, a chart...),
/// shown in place like the web's embeds. [embed] is HTML, or an address.
class EmbedView extends ConsumerStatefulWidget {
  const EmbedView({super.key, required this.embed});
  final String embed;

  @override
  ConsumerState<EmbedView> createState() => _EmbedViewState();
}

class _EmbedViewState extends ConsumerState<EmbedView> {
  late final WebViewController _web;
  double? _height;

  bool get _isAddress {
    final e = widget.embed.trim();
    return !e.contains('<') &&
        (e.startsWith('http://') ||
            e.startsWith('https://') ||
            e.startsWith('/'));
  }

  @override
  void initState() {
    super.initState();
    final client = ref.read(clientProvider);
    final params = WebViewPlatform.instance is AndroidWebViewPlatform
        ? AndroidWebViewControllerCreationParams()
        : const PlatformWebViewControllerCreationParams();
    _web = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        'NexusSize',
        onMessageReceived: (m) {
          final h = double.tryParse(m.message);
          if (h != null && h > 0 && mounted) {
            setState(() => _height = h.clamp(60, 1600).toDouble());
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (r) {
            // Players load inside frames; a link the person taps opens in
            // the browser instead of replacing the player.
            if (!r.isMainFrame ||
                r.url.startsWith('about:') ||
                r.url.startsWith('data:') ||
                r.url == _start) {
              return NavigationDecision.navigate;
            }
            launchUrl(Uri.parse(r.url), mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          },
        ),
      );
    final android = _web.platform;
    if (android is AndroidWebViewController) {
      // Videos play without an extra tap once started, and go full screen.
      android.setMediaPlaybackRequiresUserGesture(false);
      android.setCustomWidgetCallbacks(
        onShowCustomWidget: (widget, hidden) {
          final route = MaterialPageRoute<void>(
            builder: (_) => _FullScreen(onClose: hidden, child: widget),
          );
          _full = route;
          Navigator.of(context).push(route);
        },
        onHideCustomWidget: () {
          // The player left full screen by itself: close only that page.
          final route = _full;
          _full = null;
          if (mounted && route != null && route.isActive) {
            Navigator.of(context).removeRoute(route);
          }
        },
      );
    }
    if (_isAddress) {
      final uri = client.serverUri(widget.embed.trim());
      _start = uri.toString();
      final own = uri.host == Uri.parse(client.baseUrl).host;
      _web.loadRequest(uri, headers: own ? client.authHeaders : const {});
    } else {
      // Loaded from the server's address, as the web's frame is: YouTube
      // won't play for a page with no origin.
      _web.loadHtmlString(embedPage(widget.embed), baseUrl: client.baseUrl);
    }
  }

  String? _start;
  Route<void>? _full;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final width = box.maxWidth.isFinite ? box.maxWidth : 360.0;
      final height = _height ?? (_isAddress ? 420 : width * 9 / 16);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: width,
            height: height,
            child: WebViewWidget(controller: _web),
          ),
        ),
      );
    },
  );
}

class _FullScreen extends StatefulWidget {
  const _FullScreen({required this.child, required this.onClose});
  final Widget child;
  final VoidCallback onClose;

  @override
  State<_FullScreen> createState() => _FullScreenState();
}

class _FullScreenState extends State<_FullScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    widget.onClose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(backgroundColor: Colors.black, body: widget.child);
}

/// Wraps a tool's HTML so it fits the phone: players keep their shape at
/// the full width, and the page reports its height to size the view.
String embedPage(String html) =>
    '''<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  html, body { margin: 0; padding: 0; background: transparent; }
  img, video, iframe, canvas, svg { max-width: 100%; }
  iframe { border: 0; display: block; }
</style>
</head><body>
$html
<script>
  (function () {
    for (const f of document.querySelectorAll('iframe')) {
      const w = parseFloat(f.getAttribute('width'));
      const h = parseFloat(f.getAttribute('height'));
      f.style.width = '100%';
      if (w > 0 && h > 0) {
        f.style.aspectRatio = w + ' / ' + h;
        f.style.height = 'auto';
      }
    }
    function report() {
      const h = Math.ceil(document.documentElement.getBoundingClientRect().height);
      if (window.NexusSize) NexusSize.postMessage(String(h));
    }
    new ResizeObserver(report).observe(document.documentElement);
    window.addEventListener('load', report);
    report();
  })();
</script>
</body></html>''';
