package com.nexus.nexus_assistant

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Settings > Notifications > Instant: while the app is closed, keeps one
 * light live connection to your Open WebUI server (the same Socket.IO
 * connection the web page and the app use, over https when the address is
 * https). The moment the server says a reply finished, a channel message
 * came in or the inbox changed, it runs [ServerCheck] so the notification
 * shows right away instead of at the next 15-minute check. Nothing goes
 * anywhere but your own server, and nothing is kept on the phone but the
 * sign-in [BackgroundCheck] already keeps.
 *
 * Android only keeps it running as a foreground service, so it shows a
 * small silent notification. The 15-minute check stays on as a safety net
 * and starts this again when Android stopped it.
 */
class InstantService : Service() {
    companion object {
        private const val PREFS = "nexus_instant"
        private const val CHANNEL = "instant"
        private const val ID = 4718
        private const val ACTION_RESTART = "com.nexus.nexus_assistant.INSTANT_RESTART"
        private const val ACTION_OFF = "com.nexus.nexus_assistant.INSTANT_OFF"

        @Volatile private var running = false

        /** False in builds that leave the service out (Google Play). */
        fun available(context: Context): Boolean = try {
            context.packageManager.getServiceInfo(
                ComponentName(context, InstantService::class.java),
                0,
            )
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }

        /** The phone's choice; on unless turned off. */
        fun wanted(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("on", true)

        fun isOn(context: Context): Boolean {
            if (!available(context) || !wanted(context) || !BackgroundCheck.isOn(context)) {
                return false
            }
            // Anything leaving the house is encrypted: plain ws only at home.
            val base = context.getSharedPreferences(BackgroundCheck.PREFS, Context.MODE_PRIVATE)
                .getString("baseUrl", null) ?: return false
            return !InstantProtocol.insecureRemote(base)
        }

        fun setWanted(context: Context, on: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean("on", on).apply()
            sync(context)
        }

        /**
         * Starts or stops the connection to match the settings. [restart]
         * reconnects with a new sign-in. Android only lets this start while
         * the app is open, after a restart or an update, or when OpenAide
         * may ignore battery optimization; otherwise it waits for one of those.
         */
        fun sync(context: Context, restart: Boolean = false) {
            val intent = Intent(context, InstantService::class.java)
            if (!isOn(context)) {
                if (running) context.stopService(intent)
                return
            }
            if (running && !restart) return
            if (restart) intent.action = ACTION_RESTART
            try {
                if (Build.VERSION.SDK_INT >= 26) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {
                // Not allowed from the background right now: the app, the
                // next check or the next restart starts it.
            }
        }

        /** Whether Android lets OpenAide keep its connection while the phone sleeps. */
        fun ignoringBattery(context: Context): Boolean =
            context.getSystemService(PowerManager::class.java)
                .isIgnoringBatteryOptimizations(context.packageName)

        /** Asks Android to let OpenAide run while the phone sleeps. */
        fun askBattery(context: Context) {
            val ask = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${context.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                context.startActivity(ask)
            } catch (_: Exception) {
                // Some phones hide the direct ask: open the list instead.
                context.startActivity(
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            }
        }
    }

    private val thread = HandlerThread("instant").also { it.start() }
    private val handler = Handler(thread.looper)
    private val checks = Executors.newSingleThreadExecutor()
    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private var socket: WebSocket? = null
    private var connected = false
    private var backoff = 2_000L
    private var silentLimit = 90_000L
    private var callback: ConnectivityManager.NetworkCallback? = null

    private val reconnect = Runnable { connect() }
    private val watchdog = Runnable {
        // No ping from the server for too long: the line is dead.
        socket?.cancel()
    }
    private val check = Runnable { runCheck() }
    private val checkAgain = Runnable { runCheck() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        val net = getSystemService(ConnectivityManager::class.java)
        callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // Back online, or a new network: reconnect now, not after the wait.
                handler.post {
                    if (!connected && socket == null) {
                        backoff = 2_000L
                        handler.removeCallbacks(reconnect)
                        connect()
                    }
                }
            }
        }.also {
            try {
                net.registerDefaultNetworkCallback(it)
            } catch (_: Exception) {
                callback = null
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_OFF) {
            setWanted(this, false)
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(
                    ID,
                    notification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING,
                )
            } else {
                startForeground(ID, notification())
            }
        } catch (_: Exception) {
            // Restarted by Android from the background where that isn't
            // allowed: the app or the next check starts it again.
            stopSelf()
            return START_NOT_STICKY
        }
        if (!isOn(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        val restart = intent?.action == ACTION_RESTART
        handler.post {
            if (restart || socket == null) {
                backoff = 2_000L
                handler.removeCallbacks(reconnect)
                connect()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        callback?.let {
            try {
                getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        handler.removeCallbacksAndMessages(null)
        socket?.close(1000, null)
        socket = null
        checks.shutdownNow()
        thread.quitSafely()
        super.onDestroy()
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL,
                    "Instant notifications (connection)",
                    NotificationManager.IMPORTANCE_MIN,
                ).apply { setShowBadge(false) },
            )
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val off = PendingIntent.getService(
            this,
            1,
            Intent(this, InstantService::class.java).setAction(ACTION_OFF),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Instant notifications are on")
            .setContentText("Connected to your server. Turn off to check every 15 minutes instead.")
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Turn off", off).build())
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    // ---- The connection (Engine.IO 4 / Socket.IO 5 over a web socket) ----

    /** The sign-in BackgroundCheck keeps, or null when signed out. */
    private fun signIn(): Triple<String, String, String>? {
        val prefs = getSharedPreferences(BackgroundCheck.PREFS, Context.MODE_PRIVATE)
        val base = prefs.getString("baseUrl", null) ?: return null
        val token = prefs.getString("token", null)?.let(KeystoreBox::open) ?: return null
        val cookie = prefs.getString("cookie", "")?.let(KeystoreBox::open) ?: ""
        return Triple(base, token, cookie)
    }

    private fun connect() {
        socket?.cancel()
        socket = null
        connected = false
        val (base, token, cookie) = signIn() ?: run {
            stopSelf()
            return
        }
        // Anything leaving the house is encrypted: plain ws only at home.
        if (InstantProtocol.insecureRemote(base)) {
            stopSelf()
            return
        }
        val request = Request.Builder().url(InstantProtocol.socketUrl(base)).apply {
            if (cookie.isNotEmpty()) header("Cookie", cookie)
        }.build()
        socket = http.newWebSocket(request, Listener(token))
        // Give the server a while to answer before calling the line dead.
        handler.removeCallbacks(watchdog)
        handler.postDelayed(watchdog, 30_000L)
    }

    private fun retryLater() {
        connected = false
        socket = null
        handler.removeCallbacks(watchdog)
        handler.removeCallbacks(reconnect)
        handler.postDelayed(reconnect, backoff)
        backoff = (backoff * 2).coerceAtMost(5 * 60_000L)
    }

    private fun alive() {
        handler.removeCallbacks(watchdog)
        handler.postDelayed(watchdog, silentLimit)
    }

    private inner class Listener(private val token: String) : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            handler.post {
                if (webSocket !== socket) return@post
                onPacket(webSocket, token, text)
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            handler.post { if (webSocket === socket) retryLater() }
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            handler.post { if (webSocket === socket) retryLater() }
        }
    }

    private fun onPacket(webSocket: WebSocket, token: String, text: String) {
        alive()
        when {
            // Engine.IO open: timings, then the Socket.IO connect with the sign-in.
            text.startsWith("0") -> {
                try {
                    val open = JSONObject(text.substring(1))
                    silentLimit = open.optLong("pingInterval", 25_000L) +
                        open.optLong("pingTimeout", 20_000L) + 10_000L
                } catch (_: Exception) {
                }
                alive()
                webSocket.send(InstantProtocol.connect(token))
            }
            // Ping from the server.
            text == "2" -> webSocket.send("3")
            // Connected: join your rooms (your chats and your channels).
            text.startsWith("40") -> {
                connected = true
                backoff = 2_000L
                webSocket.send(InstantProtocol.join(token))
                // Catch up on anything from while the line was down.
                soon(followUp = false)
            }
            // Refused (signed out on the server): try again later.
            text.startsWith("44") -> {
                webSocket.close(1000, null)
                retryLater()
            }
            // The server closed this socket.
            text.startsWith("41") || text == "1" -> {
                webSocket.close(1000, null)
                retryLater()
            }
            text.startsWith("42") -> try {
                val packet = JSONArray(text.substring(2))
                when (InstantProtocol.wake(packet.optString(0), packet.opt(1))) {
                    InstantProtocol.Wake.NOW -> soon(followUp = false)
                    // A reply is saved just after it's done: look again a bit later too.
                    InstantProtocol.Wake.NOW_AND_LATER -> soon(followUp = true)
                    InstantProtocol.Wake.NO -> {}
                }
            } catch (_: Exception) {
                // Not for us.
            }
        }
    }

    /** Checks shortly, so a burst of events makes one check. */
    private fun soon(followUp: Boolean) {
        handler.removeCallbacks(check)
        handler.postDelayed(check, 1_500L)
        if (followUp) {
            handler.removeCallbacks(checkAgain)
            handler.postDelayed(checkAgain, 8_000L)
        }
    }

    private fun runCheck() {
        try {
            checks.execute {
                try {
                    ServerCheck(this).run()
                } catch (_: Exception) {
                    // Offline for a moment: the next event or check catches up.
                }
            }
        } catch (_: Exception) {
            // Shutting down.
        }
    }
}

/** After a restart or an app update, Android lets the connection start again. */
class InstantStarter : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            -> InstantService.sync(context)
        }
    }
}

/**
 * The parts of the connection that don't need Android: addresses, the
 * packets sent, and which server events are worth a check.
 */
object InstantProtocol {
    enum class Wake { NO, NOW, NOW_AND_LATER }

    /** Socket.IO connect with the sign-in, as the web page sends it. */
    fun connect(token: String): String = "40" + JSONObject().put("token", token)

    /** Joins your rooms: your chats, and your channels when you may use them. */
    fun join(token: String): String = "42" + JSONArray()
        .put("user-join")
        .put(JSONObject().put("auth", JSONObject().put("token", token)))

    /** Whether a server event ([name], [data]) may mean news to show. */
    fun wake(name: String, data: Any?): Wake {
        val body = data as? JSONObject
        return when (name) {
            // A chat's reply: only once it's done (or failed), not each word.
            "events" -> {
                val event = body?.optJSONObject("data") ?: return Wake.NO
                val inner = event.optJSONObject("data")
                val finished = when (event.optString("type")) {
                    "chat:completion", "response:completion" ->
                        inner != null && (inner.optBoolean("done") || inner.has("error"))
                    "chat:active" -> inner != null && !inner.optBoolean("active", true)
                    "chat:message:error" -> true
                    else -> false
                }
                if (finished) Wake.NOW_AND_LATER else Wake.NO
            }
            // A new message in one of your channels or DMs.
            "events:channel" ->
                if (body?.optJSONObject("data")?.optString("type") == "message") Wake.NOW else Wake.NO
            // Open WebUI 0.13: comments, mentions, replies, failed automations.
            "notifications:changed" -> Wake.NOW
            else -> Wake.NO
        }
    }

    /** Plain http to somewhere on the internet (as local_network.dart). */
    fun insecureRemote(base: String): Boolean {
        val uri = try {
            java.net.URI(base)
        } catch (_: Exception) {
            return true
        }
        return uri.scheme == "http" && !localHost(uri.host ?: "")
    }

    /**
     * This phone or the home network: a private, loopback, link-local or
     * CGNAT address, a name with no dots, or a home suffix like .lan.
     */
    fun localHost(host: String): Boolean {
        var h = host.lowercase().removePrefix("[").removeSuffix("]").removeSuffix(".")
        val v4 = h.split(".").mapNotNull { it.toIntOrNull() }
        if (v4.size == 4 && h.count { it == '.' } == 3) {
            val (a, b) = v4
            return a == 0 || a == 10 || a == 127 || (a == 169 && b == 254) ||
                (a == 172 && b in 16..31) || (a == 192 && b == 168) ||
                (a == 100 && b in 64..127)
        }
        if (h.contains(':')) {
            h = h.removePrefix("::ffff:")
            if (h.contains('.')) return localHost(h)
            return h == "::1" || h == "::" || h.startsWith("fc") || h.startsWith("fd") ||
                h.startsWith("fe8") || h.startsWith("fe9") || h.startsWith("fea") ||
                h.startsWith("feb")
        }
        if (h.isEmpty() || !h.contains('.')) return true
        return h == "localhost" || listOf(
            ".localhost", ".local", ".lan", ".home", ".home.arpa",
            ".internal", ".intranet", ".localdomain",
        ).any { h.endsWith(it) }
    }

    /** ws(s)://host[/sub-path]/ws/socket.io/, like the app's own socket. */
    fun socketUrl(base: String): String {
        val trimmed = base.trimEnd('/')
        val ws = when {
            trimmed.startsWith("https://") -> "wss://" + trimmed.removePrefix("https://")
            trimmed.startsWith("http://") -> "ws://" + trimmed.removePrefix("http://")
            else -> trimmed
        }
        return "$ws/ws/socket.io/?EIO=4&transport=websocket"
    }
}
