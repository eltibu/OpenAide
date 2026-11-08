import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'i18n/app_strings.dart';
import 'platform_caps.dart';

/// Flutter's web view has no Windows or Linux version. Without one, every
/// screen that shows a web page (artifacts, Mermaid, PDFs, the server's own
/// pages...) would crash there. This stands in for it: the screen opens as
/// usual and the web part becomes a card that opens the same page in the
/// computer's browser.
void installDesktopWebViewFallback() {
  if (PlatformCaps.webView) return;
  WebViewPlatform.instance = _FallbackPlatform();
}

class _FallbackPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _FallbackController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FallbackDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FallbackWidget(params);

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) => _FallbackCookies(params);
}

/// Remembers what the screen asked to show, so the card can open it.
class _FallbackController extends PlatformWebViewController {
  _FallbackController(super.params) : super.implementation();

  final page = ValueNotifier<_Page?>(null);

  @override
  Future<void> loadRequest(LoadRequestParams params) async =>
      page.value = _Page(url: params.uri);

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async =>
      page.value = _Page(html: html);

  @override
  Future<void> loadFile(String absoluteFilePath) async =>
      page.value = _Page(url: Uri.file(absoluteFilePath));

  @override
  Future<void> loadFlutterAsset(String key) async {}

  @override
  Future<String?> currentUrl() async => page.value?.url?.toString();

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<bool> canGoForward() async => false;

  @override
  Future<void> goBack() async {}

  @override
  Future<void> goForward() async {}

  @override
  Future<void> reload() async {}

  @override
  Future<void> clearCache() async {}

  @override
  Future<void> clearLocalStorage() async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async => '';

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {}

  @override
  Future<void> removeJavaScriptChannel(String javaScriptChannelName) async {}

  @override
  Future<String?> getTitle() async => null;

  @override
  Future<void> scrollTo(int x, int y) async {}

  @override
  Future<void> scrollBy(int x, int y) async {}

  @override
  Future<Offset> getScrollPosition() async => Offset.zero;

  @override
  Future<void> setVerticalScrollBarEnabled(bool enabled) async {}

  @override
  Future<void> setHorizontalScrollBarEnabled(bool enabled) async {}

  @override
  Future<void> enableZoom(bool enabled) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setUserAgent(String? userAgent) async {}

  @override
  Future<String?> getUserAgent() async => null;

  @override
  Future<void> setOnPlatformPermissionRequest(
    void Function(PlatformWebViewPermissionRequest request) onPermissionRequest,
  ) async {}

  @override
  Future<void> setOnConsoleMessage(
    void Function(JavaScriptConsoleMessage consoleMessage) onConsoleMessage,
  ) async {}

  @override
  Future<void> setOnScrollPositionChange(
    void Function(ScrollPositionChange scrollPositionChange)?
    onScrollPositionChange,
  ) async {}

  @override
  Future<void> setOnJavaScriptAlertDialog(
    Future<void> Function(JavaScriptAlertDialogRequest request)
    onJavaScriptAlertDialog,
  ) async {}

  @override
  Future<void> setOnJavaScriptConfirmDialog(
    Future<bool> Function(JavaScriptConfirmDialogRequest request)
    onJavaScriptConfirmDialog,
  ) async {}

  @override
  Future<void> setOnJavaScriptTextInputDialog(
    Future<String> Function(JavaScriptTextInputDialogRequest request)
    onJavaScriptTextInputDialog,
  ) async {}
}

class _Page {
  const _Page({this.url, this.html});
  final Uri? url;
  final String? html;
}

class _FallbackDelegate extends PlatformNavigationDelegate {
  _FallbackDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {}

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}

  @override
  Future<void> setOnHttpAuthRequest(
    HttpAuthRequestCallback onHttpAuthRequest,
  ) async {}

  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback onSslAuthError) async {}
}

class _FallbackCookies extends PlatformWebViewCookieManager {
  _FallbackCookies(super.params) : super.implementation();

  @override
  Future<bool> clearCookies() async => false;

  @override
  Future<void> setCookie(WebViewCookie cookie) async {}
}

class _FallbackWidget extends PlatformWebViewWidget {
  _FallbackWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    final controller = params.controller;
    if (controller is! _FallbackController) return const SizedBox.shrink();
    return ValueListenableBuilder(
      valueListenable: controller.page,
      builder: (context, page, _) => _OpenInBrowserCard(page: page),
    );
  }
}

class _OpenInBrowserCard extends StatelessWidget {
  const _OpenInBrowserCard({required this.page});
  final _Page? page;

  Future<void> _open() async {
    final page = this.page;
    if (page == null) return;
    var url = page.url;
    if (url == null && page.html != null) {
      // Saved as a file the browser can open; it stays on this computer.
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/openaide-${DateTime.now().millisecondsSinceEpoch}.html',
      );
      await file.writeAsString(page.html!);
      url = Uri.file(file.path);
    }
    if (url != null) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        // Some screens keep a hidden 1-pixel web view; leave those empty.
        if (box.maxHeight < 48 || box.maxWidth < 120) {
          return const SizedBox.shrink();
        }
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.open_in_browser,
                  size: 32,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 8),
                T(
                  'This view opens in your browser on this computer.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: page == null ? null : _open,
                  icon: const Icon(Icons.open_in_new),
                  label: const T('Open in browser'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
