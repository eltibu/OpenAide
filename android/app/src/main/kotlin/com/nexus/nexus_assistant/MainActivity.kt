package com.nexus.nexus_assistant

import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Lets Dart read the WebView's cookies, including HttpOnly ones such as
        // a reverse proxy's session cookie, after an in-app SSO sign-in.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nexus/cookies")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "get" -> {
                        val manager = CookieManager.getInstance()
                        manager.flush()
                        result.success(manager.getCookie(call.argument<String>("url")))
                    }
                    "clear" -> CookieManager.getInstance().removeAllCookies { result.success(it) }
                    else -> result.notImplemented()
                }
            }
    }
}
