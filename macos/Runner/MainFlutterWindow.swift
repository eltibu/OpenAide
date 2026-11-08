import Cocoa
import FlutterMacOS
import WebKit

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    OpenAideCookies.register(flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
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
          let mine = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
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
