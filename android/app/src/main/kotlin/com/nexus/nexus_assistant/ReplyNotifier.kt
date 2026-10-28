package com.nexus.nexus_assistant

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Settings > Notifications: a phone notification when a reply finishes while
 * the app is in the background. Tapping it opens that chat (Dart is told
 * through "open", or asks for [initialChat] after a cold start).
 */
class ReplyNotifier(private val activity: Activity) : MethodChannel.MethodCallHandler {
    var channel: MethodChannel? = null
    private var pendingAsk: MethodChannel.Result? = null
    private var initialChat: String? = null

    companion object {
        // Not the microphone's 4711: a shared code handed each ask the other's answer.
        const val PERMISSION_REQUEST = 4721
        const val EXTRA_CHAT = "nexus.chatId"
        private const val SOUND = "replies"
        private const val QUIET = "replies_quiet"
    }

    private val manager get() =
        activity.getSystemService(NotificationManager::class.java)

    // Made up front so Nexus and its kinds of notification show in Android's
    // settings before the first one arrives.
    init {
        ensureChannels()
    }

    private fun allowed(): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT < 26) return
        manager.createNotificationChannel(
            NotificationChannel(SOUND, "Replies", NotificationManager.IMPORTANCE_DEFAULT),
        )
        manager.createNotificationChannel(
            NotificationChannel(QUIET, "Replies (silent)", NotificationManager.IMPORTANCE_LOW)
                .apply { setSound(null, null) },
        )
    }

    /** Remembers the chat a notification was opened for. */
    fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val id = intent.getStringExtra(EXTRA_CHAT) ?: return
        intent.removeExtra(EXTRA_CHAT)
        val ch = channel
        if (ch != null) ch.invokeMethod("open", id) else initialChat = id
    }

    /** After a cold start Dart isn't listening yet, so it asks instead. */
    fun rememberInitial(intent: Intent?) {
        if (intent == null) return
        initialChat = intent.getStringExtra(EXTRA_CHAT) ?: return
        intent.removeExtra(EXTRA_CHAT)
    }

    fun onPermission(granted: Boolean) {
        pendingAsk?.success(granted)
        pendingAsk = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "allowed" -> result.success(
                allowed() && (Build.VERSION.SDK_INT < 24 || manager.areNotificationsEnabled()),
            )
            // Android's notification settings for Nexus, for when the ask
            // was turned down before and Android won't ask again.
            "openSettings" -> {
                val open = if (Build.VERSION.SDK_INT >= 26) {
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                } else {
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        .setData(android.net.Uri.parse("package:${activity.packageName}"))
                }
                activity.startActivity(open)
                result.success(null)
            }
            "ask" -> {
                if (allowed()) {
                    result.success(true)
                } else {
                    pendingAsk?.success(false)
                    pendingAsk = result
                    activity.requestPermissions(
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        PERMISSION_REQUEST,
                    )
                }
            }
            // While the app is closed: see BackgroundCheck.
            "background" -> {
                BackgroundCheck.configure(
                    activity,
                    call.argument<Boolean>("enabled") ?: false,
                    call.argument<String>("baseUrl"),
                    call.argument<String>("token"),
                    call.argument<String>("cookie"),
                )
                result.success(null)
            }
            "backgroundOn" -> result.success(BackgroundCheck.isOn(activity))
            "initialChat" -> {
                result.success(initialChat)
                initialChat = null
            }
            "notify" -> {
                if (!allowed()) {
                    result.success(false)
                    return
                }
                ensureChannels()
                val chat = call.argument<String>("chatId") ?: ""
                val open = Intent(activity, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    putExtra(EXTRA_CHAT, chat)
                }
                val tap = PendingIntent.getActivity(
                    activity,
                    chat.hashCode(),
                    open,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                val sound = call.argument<Boolean>("sound") ?: true
                val builder = if (Build.VERSION.SDK_INT >= 26) {
                    Notification.Builder(activity, if (sound) SOUND else QUIET)
                } else {
                    @Suppress("DEPRECATION")
                    Notification.Builder(activity)
                }
                val body = call.argument<String>("body") ?: ""
                val notification = builder
                    .setSmallIcon(R.mipmap.ic_launcher)
                    .setContentTitle(call.argument<String>("title") ?: "OpenAide")
                    .setContentText(body)
                    .setStyle(Notification.BigTextStyle().bigText(body))
                    .setContentIntent(tap)
                    .setAutoCancel(true)
                    .build()
                manager.notify(chat.hashCode(), notification)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }
}
