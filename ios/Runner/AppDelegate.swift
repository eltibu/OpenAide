import Flutter
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OpenAideCookies") {
      OpenAideCookies.register(registrar.messenger())
    }
  }
}

/// The in-app browser's cookies for a server, after a browser (SSO) sign-in,
/// so the app's own requests also pass a login page in front of Open WebUI.
/// Same calls as Android's MainActivity.kt on `nexus/cookies`.
enum OpenAideCookies {
  static func register(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "nexus/cookies", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let store = WKWebsiteDataStore.default()
      switch call.method {
      case "get":
        let args = call.arguments as? [String: Any]
        guard let url = (args?["url"] as? String).flatMap({ URL(string: $0) }),
          let host = url.host
        else {
          result(nil)
          return
        }
        store.httpCookieStore.getAllCookies { cookies in
          // Only what a browser would send to this address: host-only
          // cookies for exactly this host, domain cookies for it and its
          // subdomains, Secure cookies only over https.
          let secure = url.scheme?.lowercased() == "https"
          let lowerHost = host.lowercased()
          let mine = cookies.filter { cookie in
            if cookie.isSecure && !secure { return false }
            let raw = cookie.domain.lowercased()
            if raw.hasPrefix(".") {
              let domain = String(raw.dropFirst())
              return lowerHost == domain || lowerHost.hasSuffix("." + domain)
            }
            return lowerHost == raw
          }
          result(mine.isEmpty ? nil : mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
        }
      // Sign-out: cookies and the page storage that holds the Open WebUI
      // token, so the next sign-in really asks.
      case "clear":
        store.removeData(
          ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
          modifiedSince: Date(timeIntervalSince1970: 0)
        ) { result(true) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
