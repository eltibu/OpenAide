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
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import io.socket.client.IO
import io.socket.client.Socket
import io.socket.engineio.client.transports.WebSocket
import org.json.JSONObject
import java.net.URI

/**
 * Settings > Notifications > While the app is closed > Instant: keeps the
 * live connection to the server (Open WebUI's Socket.IO, as the app uses
 * while open) after the app closes. When the server says a reply finished,
 * a channel message came, the inbox or the chat list changed, the closed-app
 * check ([BackgroundCheck]) runs at once instead of in up to 15 minutes. The
 * signal carries no text; the check reads the server. Android shows a silent
 * notification while it listens. The Google Play build leaves it out (see
 * src/play/AndroidManifest.xml).
 */
class LiveListen : Service() {
    companion object {
        // Kept with the closed-app check's address and sign-in.
        private const val PREFS = "nexus_background"
        private const val CHANNEL = "listening"
        private const val ID = 4717
        private const val ACTION_OFF = "com.nexus.nexus_assistant.LISTEN_OFF"
        private const val ACTION_POKE = "com.nexus.nexus_assistant.LISTEN_POKE"

        // Lets a page open on another device mark the reply read first.
        private const val SETTLE = 3000L

        // Longest the phone is kept awake for one check (its requests time out sooner).
        private const val AWAKE = 90_000L

        fun isOn(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("instant", false)

        /** Whether this build has it. */
        fun available(context: Context): Boolean = try {
            context.packageManager.getServiceInfo(ComponentName(context, LiveListen::class.java), 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }

        /**
         * Starts or stops it to match the setting. Android only lets it
         * start while the app is open, after a restart or after an update.
         */
        fun update(context: Context) {
            if (!available(context)) return
            val intent = Intent(context, LiveListen::class.java)
            if (!BackgroundCheck.isOn(context) || !isOn(context)) {
                context.stopService(intent)
                return
            }
            try {
                context.startForegroundService(intent)
            } catch (_: Exception) {
                // Not allowed from the background: it starts next time the app opens.
            }
        }

        /** From the 15-minute check: connect again if the line dropped. */
        fun poke(context: Context) {
            if (!available(context) || !isOn(context)) return
            try {
                context.startService(Intent(context, LiveListen::class.java).setAction(ACTION_POKE))
            } catch (_: Exception) {
                // Not running and the app is closed: it starts next time the app opens.
            }
        }
    }

    /** Starts it again after the phone restarts or the app is updated. */
    class Restart : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
                intent.action == Intent.ACTION_MY_PACKAGE_REPLACED
            ) {
                update(context)
            }
        }
    }

    private val thread = HandlerThread("LiveListen").apply { start() }
    private val handler = Handler(thread.looper)
    private var socket: Socket? = null
    private var signedIn: String? = null
    private var pending = false
    private var lastNetwork: Network? = null
    private var watching = false

    private val lock by lazy {
        getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "OpenAide:listen")
            .apply { setReferenceCounted(false) }
    }

    private val check = Runnable {
        pending = false
        try {
            BackgroundCheck.checkNow(this@LiveListen)
        } catch (_: Exception) {
            // Offline or signed out: the next signal or the 15-minute check tries again.
        }
        if (!pending && lock.isHeld) lock.release()
    }

    // A new network (Wi-Fi to mobile and back): the old line is dead even if
    // it hasn't noticed yet.
    private val network = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(net: Network) {
            handler.post {
                val before = lastNetwork
                lastNetwork = net
                if (before != null && before != net) reconnect()
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_OFF) {
            getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("instant", false).apply()
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(ID, notification())
            }
        } catch (_: Exception) {
            // Restarted by the system while the app is closed and Android
            // doesn't allow it now: the 15-minute check carries on, and the
            // app starts this again when it opens.
            stopSelf()
            return START_NOT_STICKY
        }
        if (!watching) {
            getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(network)
            watching = true
        }
        val poke = intent?.action == ACTION_POKE
        handler.post {
            val s = socket
            if (poke && s != null && !s.connected()) s.connect() else connect()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        if (watching) {
            try {
                getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(network)
            } catch (_: Exception) {
            }
        }
        handler.post {
            socket?.off()
            socket?.close()
            socket = null
            thread.quitSafely()
        }
        if (lock.isHeld) lock.release()
        super.onDestroy()
    }

    /** Connects with the current sign-in; again only when it changed. */
    private fun connect() {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val base = prefs.getString("baseUrl", null)
        val token = prefs.getString("token", null)?.let(KeystoreBox::open)
        if (base.isNullOrEmpty() || token.isNullOrEmpty() || !prefs.getBoolean("instant", false)) {
            stopSelf()
            return
        }
        val cookie = prefs.getString("cookie", "")?.let(KeystoreBox::open) ?: ""
        val key = "$base\n$token\n$cookie"
        if (key == signedIn && socket != null) return
        socket?.off()
        socket?.close()

        val uri = URI(base.trimEnd('/'))
        val options = IO.Options().apply {
            // Keeps a sub-path such as http://host/chat working.
            path = (uri.path ?: "").trimEnd('/') + "/ws/socket.io"
            transports = arrayOf(WebSocket.NAME)
            auth = mapOf("token" to token)
            if (cookie.isNotEmpty()) extraHeaders = mapOf("Cookie" to listOf(cookie))
            forceNew = true
            reconnection = true
            reconnectionDelay = 2000
            reconnectionDelayMax = 60000
        }
        val s = IO.socket(URI(uri.scheme, null, uri.host, uri.port, null, null, null), options)
        s.on(Socket.EVENT_CONNECT) {
            // Channel messages come to the channels' rooms, joined here.
            s.emit("user-join", JSONObject().put("auth", JSONObject().put("token", token)))
            // Anything that came while the line was down.
            ring()
        }
        s.on("events") { args ->
            val data = (args.firstOrNull() as? JSONObject)?.optJSONObject("data")
            val inner = data?.optJSONObject("data")
            when (data?.optString("type")) {
                "chat:active" -> if (inner?.optBoolean("active", true) == false) ring()
                "chat:completion" -> if (inner?.optBoolean("done") == true) ring()
                "chat:list" -> ring()
            }
        }
        s.on("events:channel") { args ->
            val type = (args.firstOrNull() as? JSONObject)?.optJSONObject("data")?.optString("type")
            if (type == "message") ring()
        }
        // Open WebUI 0.13 inbox: only a nudge, no content.
        s.on("notifications:changed") { ring() }
        s.connect()
        socket = s
        signedIn = key
    }

    private fun reconnect() {
        val s = socket ?: return connect()
        s.disconnect()
        s.connect()
    }

    /** Something is new: check once things settle, kept awake until then. */
    private fun ring() {
        lock.acquire(AWAKE)
        handler.post {
            // Again here: a check that just ended may have let go.
            lock.acquire(AWAKE)
            if (!pending) {
                pending = true
                handler.postDelayed(check, SETTLE)
            }
        }
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Instant (listening)", NotificationManager.IMPORTANCE_MIN)
                .apply { setShowBadge(false) },
        )
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val off = PendingIntent.getService(
            this,
            1,
            Intent(this, LiveListen::class.java).setAction(ACTION_OFF),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Listening for new messages")
            .setContentText("News shows up in seconds. Tap Turn off to go back to every 15 minutes.")
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Turn off", off).build())
            .setOngoing(true)
            .build()
    }
}
