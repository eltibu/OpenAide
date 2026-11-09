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
import android.content.ContextWrapper
import android.content.Intent
import android.os.Build
import org.json.JSONArray
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * Settings > Notifications > While the app is closed: about every 15
 * minutes (and right away when [InstantService] hears from the server)
 * Android lets this ask the server for chats with a new, unread
 * reply, channels with unread messages and new inbox items (comments,
 * mentions, failed automations, coming events), and posts a notification
 * for each. Nothing is kept but the time of the last check and the sign-in
 * (sealed by [KeystoreBox]); the server stays the source of truth. Dart hands over the address and sign-in through
 * [configure] (see reply_notify.dart).
 */
class BackgroundCheck : JobService() {
    companion object {
        private const val JOB = 4712
        internal const val PREFS = "nexus_background"
        internal const val CHANNEL = "background"

        /** At most this many inbox pages (of 20) per check. */
        internal const val MAX_INBOX_PAGES = 25

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
                InstantService.sync(context)
                return
            }
            val edit = prefs.edit()
                .putString("baseUrl", baseUrl)
                .putString("token", KeystoreBox.seal(token))
                .putString("cookie", KeystoreBox.seal(cookie ?: ""))
            // Start from now: only what arrives later is news.
            if (!prefs.contains("since")) edit.putLong("since", System.currentTimeMillis() / 1000)
            edit.commit()
            // A new sign-in: the live connection starts again with it.
            InstantService.sync(context, restart = true)
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
                // The live connection may have been stopped by Android;
                // this brings it back where Android allows it.
                InstantService.sync(this)
                ServerCheck(this).run()
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

/**
 * The check itself, shared by the 15-minute job and [InstantService] (which
 * runs it the moment the server says something changed).
 */
class ServerCheck(base: Context) : ContextWrapper(base) {
    private companion object {
        val LOCK = Any()
        const val PREFS = BackgroundCheck.PREFS
        const val CHANNEL = BackgroundCheck.CHANNEL
        const val MAX_INBOX_PAGES = BackgroundCheck.MAX_INBOX_PAGES
        val appVisible: Boolean get() = BackgroundCheck.appVisible
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

    /** One check at a time, whether the 15-minute job or [InstantService] asked. */
    fun run() = synchronized(LOCK) { check() }

    /** What was already shown, so a second look doesn't show it again. */
    private var told = org.json.JSONObject()

    private fun check() {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        told = try {
            org.json.JSONObject(prefs.getString("told", "{}") ?: "{}")
        } catch (_: Exception) {
            org.json.JSONObject()
        }
        val base = prefs.getString("baseUrl", null) ?: return
        val token = prefs.getString("token", null)?.let(KeystoreBox::open) ?: return
        val cookie = prefs.getString("cookie", "")?.let(KeystoreBox::open) ?: ""
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
            val title = text(c, "title").ifEmpty { "OpenAide" }
            post(
                text(c, "id").hashCode(),
                title,
                text(c, "snippet").ifEmpty { "New reply" },
                text(c, "id"),
                "$updated",
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
                    "$last",
                )
            }
        } catch (_: Exception) {
            // Channels may be off on this server.
        }
        // Open WebUI 0.13 inbox: comments, replies and mentions on your
        // things, failed automations and coming events, unseen and new since
        // the last check. Channel news is counted above already.
        // Newest first, a page at a time: keep reading until the items are
        // older than the last check, so a busy spell isn't cut off at one page.
        try {
            var cursor: String? = null
            var pages = 0
            paging@ while (pages++ < MAX_INBOX_PAGES) {
                val query = "limit=20" + (cursor?.let { "&cursor=" + URLEncoder.encode(it, "UTF-8") } ?: "")
                val page = org.json.JSONObject(
                    get(base, "/api/v1/notifications/inbox?$query", token, cookie),
                )
                val inbox = page.optJSONArray("items") ?: JSONArray()
                var reachedOld = inbox.length() == 0
                for (i in 0 until inbox.length()) {
                    val n = inbox.getJSONObject(i)
                    // created_at is epoch nanoseconds, sent as text.
                    val created = (text(n, "created_at").toLongOrNull() ?: 0L) / 1_000_000_000L
                    if (created <= since) {
                        reachedOld = true
                        continue
                    }
                    val event = text(n, "event_type")
                    if (event.startsWith("channel.") || !n.isNull("seen_at")) continue
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
                        ("inbox:" + text(n, "id")).hashCode(),
                        label,
                        listOf(title, preview).filter { it.isNotEmpty() }.joinToString("\n")
                            .ifEmpty { "Open your inbox" },
                        if (text(n, "resource_type") == "chat") text(n, "resource_id") else null,
                        "1",
                    )
                }
                cursor = if (page.isNull("next_cursor")) null else page.optString("next_cursor")
                if (reachedOld || cursor.isNullOrEmpty()) break@paging
            }
        } catch (_: Exception) {
            // Servers before 0.13, or the inbox is off.
        }
        // A second back: something saved in the same second as this check
        // started is still news next time (at worst it updates quietly).
        if (told.length() > 300) told = org.json.JSONObject()
        prefs.edit()
            .putLong("since", now - 1)
            .putString("told", told.toString())
            .apply()
    }

    /** A string field; JSON null and missing read as empty. */
    private fun text(o: org.json.JSONObject, key: String): String =
        if (o.isNull(key)) "" else o.optString(key)

    private fun post(id: Int, title: String, body: String, chatId: String?, marker: String) {
        if (told.optString("$id") == marker) return
        told.put("$id", marker)
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
        // The app may have just shown this one itself (its own live
        // connection was still up): update it without a second sound.
        val recent = manager.activeNotifications.any {
            it.id == id && System.currentTimeMillis() - it.postTime < 60_000
        }
        manager.notify(
            id,
            builder
                .setOnlyAlertOnce(recent)
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
