import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/desktop_web_view.dart';
import 'package:nexus_assistant/core/platform_caps.dart';
import 'package:nexus_assistant/features/update/updater.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  test('only Android has the phone-only features', () {
    expect(PlatformCaps.android, isTrue); // widget tests run as Android
    expect(PlatformCaps.phoneAssistant, isTrue);
    for (final p in [
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.iOS,
    ]) {
      debugDefaultTargetPlatformOverride = p;
      expect(PlatformCaps.phoneAssistant, isFalse, reason: '$p');
      expect(PlatformCaps.localModels, isFalse, reason: '$p');
      expect(PlatformCaps.selfInstallUpdates, isFalse, reason: '$p');
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(PlatformCaps.webView, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(PlatformCaps.webView, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  test('each computer picks its own download from a release', () {
    Map<String, dynamic> rel(String tag, List<String> assets) => {
      'tag_name': tag,
      'html_url': 'https://github.com/x/y/releases/tag/$tag',
      'assets': [
        for (final a in assets) {'name': a, 'url': 'u-$a'},
      ],
    };
    final releases = [
      rel('v0.1.300', ['OpenAide-0.1.300.apk']),
      rel('v0.1.301', [
        'OpenAide-0.1.301.apk',
        'OpenAide-windows-x64-0.1.301.zip',
        'OpenAide-linux-x64-0.1.301.tar.gz',
        'OpenAide-ios-0.1.301.ipa',
        'altstore.json',
      ]),
    ];
    final win = newestRelease(releases, isAsset: desktopAsset('windows'));
    expect(win?.build, 301);
    expect(win?.assetApiUrl, 'u-OpenAide-windows-x64-0.1.301.zip');
    expect(win?.pageUrl, endsWith('/v0.1.301'));
    expect(
      newestRelease(releases, isAsset: desktopAsset('linux'))?.assetApiUrl,
      'u-OpenAide-linux-x64-0.1.301.tar.gz',
    );
    expect(newestRelease(releases, isAsset: desktopAsset('macos')), isNull);
    expect(
      newestRelease(releases, isAsset: desktopAsset('ios'))?.assetApiUrl,
      'u-OpenAide-ios-0.1.301.ipa',
    );
    expect(newestRelease(releases)?.assetApiUrl, 'u-OpenAide-0.1.301.apk');
  });

  testWidgets('web views become an Open in browser card on Windows', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final before = WebViewPlatform.instance;
    installDesktopWebViewFallback();
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) {}))
      ..loadHtmlString('<p>hi</p>');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WebViewWidget(controller: controller)),
      ),
    );
    await tester.pump();
    expect(find.text('Open in browser'), findsOneWidget);
    expect(await controller.runJavaScriptReturningResult('1'), '');
    if (before != null) WebViewPlatform.instance = before;
    debugDefaultTargetPlatformOverride = null;
  });
}
