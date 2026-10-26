package com.nexus.nexus_assistant

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.webkit.CookieManager
import android.webkit.WebStorage
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Lets Dart read the WebView's cookies, including HttpOnly ones such as
        // a reverse proxy's session cookie, after an in-app SSO sign-in.
        MethodChannel(messenger, "nexus/cookies")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "get" -> {
                        val manager = CookieManager.getInstance()
                        manager.flush()
                        result.success(manager.getCookie(call.argument<String>("url")))
                    }
                    // Sign-out: cookies and the page storage that holds the
                    // Open WebUI token, so the next sign-in really asks.
                    "clear" -> CookieManager.getInstance().removeAllCookies {
                        WebStorage.getInstance().deleteAllData()
                        result.success(it)
                    }
                    else -> result.notImplemented()
                }
            }

        // In-app updates: Dart downloads the APK to [apkPath], then [install]
        // hands it to Android's installer.
        MethodChannel(messenger, "nexus/updates")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "apkPath" -> {
                        val dir = File(cacheDir, "updates").apply { mkdirs() }
                        result.success(File(dir, "update.apk").absolutePath)
                    }
                    "install" -> try {
                        result.success(install(File(cacheDir, "updates/update.apk")))
                    } catch (e: Exception) {
                        result.success(e.message ?: e.javaClass.simpleName)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Returns "started", or "permission" after sending the user to allow installs. */
    private fun install(apk: File): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ),
            )
            return "permission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
        startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return "started"
    }
}
