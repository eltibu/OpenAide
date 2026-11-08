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
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Settings > Notifications > While the app is closed: about every 15
 * minutes Android lets this ask the server for chats with a new, unread
 * reply, channels with unread messages and new inbox items (comments,
 * mentions, failed automations, coming events), and posts a notification
 * for each. With Instant on, [LiveListen] runs the same check the moment the
 * server says something happened. Nothing is kept but the time of the last
 * check, what was already told, and the sign-in (sealed by [KeystoreBox]);
 * the server stays the source of truth. Dart hands over the address and
 * sign-in through [configure] (see reply_notify.dart).
 */
class BackgroundCheck : JobService() {
    companion object {
        private const val JOB = 4712
        private const val PREFS = "nexus_background"
        private const val CHANNEL = "background"

        // Checks this close together may see the same second's news twice:
        // they look back this far and skip what was already told.
        private const val OVERLAP = 60L

        private val lock = Any()

        /** True while the app is on screen; it notifies by itself then. */
        @Volatile var appVisible = false

        fun isOn(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).contains("token")

        /** [instant] null keeps Instant as it is. */
        fun configure(
            context: Context,
            enabled: Boolean,
            baseUrl: String?,
            token: String?,
            cookie: String?,
            instant: Boolean? = null,
        ) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val scheduler = context.getSystemService(JobScheduler::class.java)
            if (!enabled || baseUrl.isNullOrEmpty() || token.isNullOrEmpty()) {
                prefs.edit().clear().apply()
                scheduler.cancel(JOB)
                LiveListen.update(context)
                return
            }
            val edit = prefs.edit()
                .putString("baseUrl", baseUrl)
                .putString("token", KeystoreBox.seal(token))
                .putString("cookie", KeystoreBox.seal(cookie ?: ""))
            if (instant != null) edit.putBoolean("instant", instant)
            // Start from now: only what arrives later is news.
            if (!prefs.contains("since")) edit.putLong("since", System.currentTimeMillis() / 1000)
            edit.apply()
            LiveListen.update(context)
            if (scheduler.getPendingJob(JOB) != null) return
            scheduler.schedule(
                JobInfo.Builder(JOB, ComponentName(context, BackgroundCheck::class.java))
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                    .setPeriodic(15 * 60 * 1000L)
                    .setPersisted(true)
                    .build(),
            )
        }

        /** One check now; the job and [LiveListen] take turns. */
        fun checkNow(context: Context) = synchronized(lock) { check(context) }

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

        private fun check(context: Context) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val base = prefs.getString("baseUrl", null) ?: return
            val token = prefs.getString("token", null)?.let(KeystoreBox::open) ?: return
            val cookie = prefs.getString("cookie", "")?.let(KeystoreBox::open) ?: ""
            val since = prefs.getLong("since", System.currentTimeMillis() / 1000)
            val now = System.currentTimeMillis() / 1000
            if (appVisible) {
                prefs.edit().putLong("since", now).remove("told").apply()
                return
            }
            // What was told already, by key: the news's time.
            val told = try {
                JSONObject(prefs.getString("told", null) ?: "{}")
            } catch (_: Exception) {
                JSONObject()
            }
            fun news(key: String, at: Long): Boolean {
                if (at <= since || at <= told.optLong(key)) return false
                told.put(key, at)
                return true
            }

            // Chats with a reply you haven't read since the last check.
            val chats = JSONArray(get(base, "/api/v1/chats/list?page=1", token, cookie))
            for (i in 0 until chats.length()) {
                val c = chats.getJSONObject(i)
                val updated = c.optLong("updated_at")
                if (updated <= since) continue
                if (!c.has("last_read_at") || c.isNull("last_read_at")) continue
                if (updated <= c.optLong("last_read_at")) continue
                if (!news(text(c, "id"), updated)) continue
                val title = text(c, "title").ifEmpty { "OpenAide" }
                post(
                    context,
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
                    if (!news("channel:" + text(ch, "id"), last)) continue
                    val name = text(ch, "name").ifEmpty { "Channel" }
                    post(
                        context,
                        ("channel:" + text(ch, "id")).hashCode(),
                        if (text(ch, "type") == "dm") name else "#$name",
                        if (unread == 1) "1 new message" else "$unread new messages",
                        null,
                    )
                }
            } catch (_: Exception) {
                // Channels may be off on this server.
            }
            // Open WebUI 0.13 inbox: comments, replies and mentions on your
            // things, failed automations and coming events, unseen and new since
            // the last check. Channel news is counted above already.
            try {
                val inbox = JSONObject(
                    get(base, "/api/v1/notifications/inbox?limit=20", token, cookie),
                ).optJSONArray("items") ?: JSONArray()
                for (i in 0 until inbox.length()) {
                    val n = inbox.getJSONObject(i)
                    val event = text(n, "event_type")
                    if (event.startsWith("channel.") || !n.isNull("seen_at")) continue
                    // created_at is epoch nanoseconds, sent as text.
                    val created = (text(n, "created_at").toLongOrNull() ?: 0L) / 1_000_000_000L
                    if (created <= since) continue
                    if (!news("inbox:" + text(n, "id"), created)) continue
                    val who = n.optJSONObject("actor")?.let { text(it, "name") } ?: ""
                    val label = when (event) {
                        "comment.created" -> "$who commented"
                        "comment.replied" -> "$who replied"
                        "comment.mentioned" -> "$who mentioned you"
                        "calendar.alert" -> "Upcoming event"
                        "automation.run_failed" -> "Automation failed"
                        "system.announcement" -> "Announcement"
                        else -> "Notification"
                    }.trim()
                    val title = text(n, "title")
                    val preview = text(n, "preview")
                        .replace(Regex("<@[A-Z]:[^|>]+\\|([^>]+)>"), "@$1")
                    post(
                        context,
                        ("inbox:" + text(n, "id")).hashCode(),
                        label,
                        listOf(title, preview).filter { it.isNotEmpty() }.joinToString("\n")
                            .ifEmpty { "Open your inbox" },
                        if (text(n, "resource_type") == "chat") text(n, "resource_id") else null,
                    )
                }
            } catch (_: Exception) {
                // Servers before 0.13, or the inbox is off.
            }
            val next = maxOf(since, now - OVERLAP)
            val keep = JSONObject()
            for (key in told.keys()) {
                if (told.optLong(key) > next) keep.put(key, told.optLong(key))
            }
            prefs.edit().putLong("since", next).putString("told", keep.toString()).apply()
        }

        /** A string field; JSON null and missing read as empty. */
        private fun text(o: JSONObject, key: String): String =
            if (o.isNull(key)) "" else o.optString(key)

        private fun post(context: Context, id: Int, title: String, body: String, chatId: String?) {
            if (Build.VERSION.SDK_INT >= 33 &&
                context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
            val manager = context.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL,
                        "While the app is closed",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ),
                )
            }
            val open = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                if (chatId != null) putExtra(ReplyNotifier.EXTRA_CHAT, chatId)
            }
            val tap = PendingIntent.getActivity(
                context,
                id,
                open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = if (Build.VERSION.SDK_INT >= 26) {
                Notification.Builder(context, CHANNEL)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
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

    @Volatile private var worker: Thread? = null

    override fun onStartJob(params: JobParameters): Boolean {
        // Instant on: make sure its line is up.
        LiveListen.poke(this)
        worker = Thread {
            try {
                checkNow(this)
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
}
