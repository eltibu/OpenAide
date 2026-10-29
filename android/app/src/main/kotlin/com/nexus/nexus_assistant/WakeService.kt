package com.nexus.nexus_assistant

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener
import org.vosk.android.SpeechService

/**
 * Hands-free: listens on the phone for "Hey OpenAide" and opens the
 * assistant as a long-press of power or home would. The listening runs on
 * the phone with a small offline speech model (Vosk); nothing is sent
 * anywhere until the phrase is heard. Android shows a notification while it
 * listens. Turned on in Settings > Phone and assistant.
 */
class WakeService : Service(), RecognitionListener {
    companion object {
        private const val PREFS = "nexus_assist"
        private const val CHANNEL = "nexus_wake"
        private const val ID = 4716
        private const val ACTION_OFF = "com.nexus.nexus_assistant.WAKE_OFF"
        private const val RATE = 16000f

        /** What the small English model hears for "Hey OpenAide". */
        private val PHRASES = listOf("hey open aide", "open aide", "hey open aid", "open aid")

        fun isOn(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("wake", false)

        fun modelPath(context: Context): String? =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("wakeModel", null)

        fun set(context: Context, on: Boolean, model: String?) {
            val edit = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            edit.putBoolean("wake", on)
            if (model != null) edit.putString("wakeModel", model)
            edit.apply()
            if (on) start(context) else context.stopService(Intent(context, WakeService::class.java))
        }

        private const val EXTRA_OPEN = "appOpen"

        /**
         * Called as OpenAide comes on screen ([open]) and leaves it. It only
         * listens while the app is closed, so it never takes the microphone
         * from a call or a dictation; Android only lets it start while the
         * app is open.
         */
        fun appOnScreen(context: Context, open: Boolean) {
            if (!isOn(context) || modelPath(context) == null) return
            val intent = Intent(context, WakeService::class.java).putExtra(EXTRA_OPEN, open)
            try {
                context.startForegroundService(intent)
            } catch (_: Exception) {
                // Not allowed from the background: it starts next time the app opens.
            }
        }

        fun start(context: Context) = appOnScreen(context, true)

        /** Whether the phone lets OpenAide open over other apps when it hears you. */
        fun canOpen(context: Context): Boolean = Settings.canDrawOverlays(context)
    }

    private var model: Model? = null
    private var speech: SpeechService? = null
    private val main = Handler(Looper.getMainLooper())
    private val again = Runnable { listen() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_OFF) {
            set(this, false, null)
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(ID, notification())
            }
        } catch (_: Exception) {
            // Restarted by the system while the app is closed: Android
            // doesn't allow the microphone then. The app starts it again.
            stopSelf()
            return START_NOT_STICKY
        }
        appOpen = intent?.getBooleanExtra(EXTRA_OPEN, false) ?: false
        if (appOpen) {
            main.removeCallbacks(again)
            quiet()
        } else {
            listen()
        }
        return START_STICKY
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Hands-free", NotificationManager.IMPORTANCE_MIN),
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
            Intent(this, WakeService::class.java).setAction(ACTION_OFF),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Listening for \"Hey OpenAide\"")
            .setContentText("On this phone only. Tap Turn off to stop.")
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Turn off", off).build())
            .setOngoing(true)
            .build()
    }

    /** Someone else is recording (a call, a dictation): wait for them. */
    private fun micBusy(): Boolean =
        getSystemService(AudioManager::class.java).activeRecordingConfigurations.isNotEmpty()

    private var appOpen = false

    private fun listen() {
        main.removeCallbacks(again)
        if (speech != null || appOpen) return
        if (micBusy()) {
            main.postDelayed(again, 10_000)
            return
        }
        try {
            val path = modelPath(this)
            if (path == null) {
                stopSelf()
                return
            }
            val m = model ?: Model(path).also { model = it }
            val grammar = org.json.JSONArray(PHRASES + "[unk]").toString()
            speech = SpeechService(Recognizer(m, RATE, grammar), RATE).also {
                it.startListening(this)
            }
        } catch (_: Throwable) {
            // No model, or this phone's chip isn't supported: nothing to do.
            stopSelf()
        }
    }

    private fun quiet() {
        speech?.stop()
        speech?.shutdown()
        speech = null
    }

    private fun heard(json: String, key: String) {
        val text = try {
            JSONObject(json).optString(key)
        } catch (_: Exception) {
            ""
        }
        if (PHRASES.none { text.contains(it) }) return
        // Leave the microphone to the assistant, then listen again.
        quiet()
        main.postDelayed(again, 30_000)
        val assist = Intent(Intent.ACTION_ASSIST)
            .setClass(this, AssistEntry::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(assist)
        } catch (_: Exception) {}
    }

    override fun onPartialResult(hypothesis: String) = heard(hypothesis, "partial")
    override fun onResult(hypothesis: String) = heard(hypothesis, "text")
    override fun onFinalResult(hypothesis: String) {}
    override fun onError(exception: Exception) {
        quiet()
        main.postDelayed(again, 10_000)
    }
    override fun onTimeout() {
        quiet()
        listen()
    }

    override fun onDestroy() {
        main.removeCallbacks(again)
        quiet()
        model?.close()
        model = null
        super.onDestroy()
    }
}
