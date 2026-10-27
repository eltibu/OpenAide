package com.nexus.nexus_assistant

import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.webkit.CookieManager
import android.webkit.WebStorage
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var voice: VoiceAudio? = null
    private var speech: MediaPlayer? = null
    private var speechDone: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Voice calls: microphone and speaker, see VoiceAudio.
        val audio = VoiceAudio(this).also { voice = it }
        MethodChannel(messenger, "nexus/voice").setMethodCallHandler(audio)
        EventChannel(messenger, "nexus/voice/events").setStreamHandler(audio)

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

        // Read aloud: Dart saves each spoken piece (from the server's text to
        // speech) to [dir]; [play] answers once it has been heard.
        MethodChannel(messenger, "nexus/speech")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "dir" -> result.success(
                        File(cacheDir, "speech").apply { mkdirs() }.absolutePath,
                    )
                    "play" -> play(call.argument<String>("path")!!, result)
                    "stop" -> {
                        stopSpeech()
                        result.success(null)
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == VoiceAudio.PERMISSION_REQUEST) {
            voice?.onPermission(
                grantResults.isNotEmpty() &&
                    grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED,
            )
        }
    }

    private fun play(path: String, result: MethodChannel.Result) {
        stopSpeech()
        val player = MediaPlayer()
        speech = player
        speechDone = result
        fun finish(answer: String) {
            if (speech === player) {
                speech = null
                speechDone = null
                result.success(answer)
            }
            player.release()
        }
        try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            player.setDataSource(path)
            player.setOnCompletionListener { finish("done") }
            player.setOnErrorListener { _, what, _ ->
                finish("error $what")
                true
            }
            player.setOnPreparedListener { it.start() }
            player.prepareAsync()
        } catch (e: Exception) {
            finish(e.message ?: "error")
        }
    }

    private fun stopSpeech() {
        val player = speech ?: return
        val done = speechDone
        speech = null
        speechDone = null
        try {
            player.stop()
        } catch (_: IllegalStateException) {
        }
        player.release()
        done?.success("stopped")
    }

    override fun onDestroy() {
        stopSpeech()
        voice?.stop()
        super.onDestroy()
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
