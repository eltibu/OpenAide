package com.nexus.nexus_assistant

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONArray
import java.net.HttpURLConnection
import java.net.URL

/**
 * Settings > Notifications > While the app is closed: about every 15
 * minutes Android lets this ask the server for chats with a new, unread
 * reply and channels with unread messages, and posts a notification for
 * each. Nothing is kept but the time of the last check; the server stays
 * the source of truth. Dart hands over the address and sign-in through
 * [configure] (see reply_notify.dart).
 */
class BackgroundCheck : JobService() {
    companion object {
        private const val JOB = 4712
        private const val PREFS = "nexus_background"
        private const val CHANNEL = "background"

        /** True while the app is on screen; it notifies by itself then. */
        @Volatile var appVisible = false

        fun isOn(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).contains("token")

        fun configure(
            context: Context,
            enabled: Boolean,
            baseUrl: String?,
            token: String?,
            cookie: String?,
        ) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val scheduler = context.getSystemService(JobScheduler::class.java)
            if (!enabled || baseUrl.isNullOrEmpty() || token.isNullOrEmpty()) {
                prefs.edit().clear().apply()
                scheduler.cancel(JOB)
                return
            }
            val edit = prefs.edit()
                .putString("baseUrl", baseUrl)
                .putString("token", token)
                .putString("cookie", cookie ?: "")
            // Start from now: only what arrives later is news.
            if (!prefs.contains("since")) edit.putLong("since", System.currentTimeMillis() / 1000)
            edit.apply()
            if (scheduler.getPendingJob(JOB) != null) return
            scheduler.schedule(
                JobInfo.Builder(JOB, ComponentName(context, BackgroundCheck::class.java))
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                    .setPeriodic(15 * 60 * 1000L)
                    .setPersisted(true)
                    .build(),
            )
        }
    }

    @Volatile private var worker: Thread? = null

    override fun onStartJob(params: JobParameters): Boolean {
        worker = Thread {
            try {
                check()
            } catch (_: Exception) {
                // Offline or signed out: try again next time.
            }
            jobFinished(params, false)
        }.also { it.start() }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        worker?.interrupt()
        return true
    }

    private fun get(base: String, path: String, token: String, cookie: String): String {
        val connection = URL(base.trimEnd('/') + path).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 15000
            connection.readTimeout = 20000
            connection.setRequestProperty("Authorization", "Bearer $token")
            connection.setRequestProperty("Accept", "application/json")
            if (cookie.isNotEmpty()) connection.setRequestProperty("Cookie", cookie)
            if (connection.responseCode != 200) throw IllegalStateException("${connection.responseCode}")
            return connection.inputStream.bufferedReader().use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }

    private fun check() {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val base = prefs.getString("baseUrl", null) ?: return
        val token = prefs.getString("token", null) ?: return
        val cookie = prefs.getString("cookie", "") ?: ""
        val since = prefs.getLong("since", System.currentTimeMillis() / 1000)
        val now = System.currentTimeMillis() / 1000
        if (appVisible) {
            prefs.edit().putLong("since", now).apply()
            return
        }

        // Chats with a reply you haven't read since the last check.
        val chats = JSONArray(get(base, "/api/v1/chats/list?page=1", token, cookie))
        for (i in 0 until chats.length()) {
            val c = chats.getJSONObject(i)
            val updated = c.optLong("updated_at")
            if (updated <= since) continue
            if (!c.has("last_read_at") || c.isNull("last_read_at")) continue
            if (updated <= c.optLong("last_read_at")) continue
            val title = text(c, "title").ifEmpty { "Nexus" }
            post(
                text(c, "id").hashCode(),
                title,
                text(c, "snippet").ifEmpty { "New reply" },
                text(c, "id"),
            )
        }

        // Channels with unread messages since the last check.
        try {
            val channels = JSONArray(get(base, "/api/v1/channels/", token, cookie))
            for (i in 0 until channels.length()) {
                val ch = channels.getJSONObject(i)
                val unread = ch.optInt("unread_count")
                // last_message_at is in nanoseconds.
                val last = ch.optLong("last_message_at") / 1_000_000_000L
                if (unread <= 0 || last <= since || ch.optBoolean("is_channel_muted")) continue
                val name = text(ch, "name").ifEmpty { "Channel" }
                post(
                    ("channel:" + text(ch, "id")).hashCode(),
                    if (text(ch, "type") == "dm") name else "#$name",
                    if (unread == 1) "1 new message" else "$unread new messages",
                    null,
                )
            }
        } catch (_: Exception) {
            // Channels may be off on this server.
        }
        prefs.edit().putLong("since", now).apply()
    }

    /** A string field; JSON null and missing read as empty. */
    private fun text(o: org.json.JSONObject, key: String): String =
        if (o.isNull(key)) "" else o.optString(key)

    private fun post(id: Int, title: String, body: String, chatId: String?) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    "While the app is closed",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
        val open = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (chatId != null) putExtra(ReplyNotifier.EXTRA_CHAT, chatId)
        }
        val tap = PendingIntent.getActivity(
            this,
            id,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        manager.notify(
            id,
            builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setContentIntent(tap)
                .setAutoCancel(true)
                .build(),
        )
    }
}
