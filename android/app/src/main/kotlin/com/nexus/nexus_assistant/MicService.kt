package com.nexus.nexus_assistant

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder

/**
 * Keeps the microphone going while a call or a recording runs and the phone
 * is locked or another app is in front: Android allows that only with a
 * notification showing. Tapping it comes back to Nexus.
 */
class MicService : Service() {
    companion object {
        private const val CHANNEL = "nexus_mic"
        private const val ID = 4715
        private const val EXTRA_CALL = "call"

        fun start(context: Context, call: Boolean) {
            val intent = Intent(context, MicService::class.java).putExtra(EXTRA_CALL, call)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Not allowed right now (app in the background): the call
                // still works while Nexus is on screen.
            }
        }

        /** A headset or earbud button press during a call. */
        var onButton: (() -> Unit)? = null

        fun stop(context: Context) {
            context.stopService(Intent(context, MicService::class.java))
        }
    }

    private var media: MediaSession? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        media?.release()
        media = null
        super.onDestroy()
    }

    /** Lets the headset button reach Nexus while a call runs. */
    private fun listenForButton() {
        if (media != null) return
        media = MediaSession(this, "Nexus call").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                    @Suppress("DEPRECATION")
                    val key = mediaButtonIntent.getParcelableExtra<android.view.KeyEvent>(Intent.EXTRA_KEY_EVENT)
                    if (key?.action == android.view.KeyEvent.ACTION_UP) onButton?.invoke()
                    return true
                }
            })
            setPlaybackState(
                PlaybackState.Builder()
                    .setActions(PlaybackState.ACTION_PLAY_PAUSE)
                    .setState(PlaybackState.STATE_PLAYING, 0, 1f)
                    .build(),
            )
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val call = intent?.getBooleanExtra(EXTRA_CALL, true) ?: true
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Calls and recording", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(if (call) "Call with Nexus" else "Nexus is recording")
            .setContentText("Tap to go back")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(ID, notification)
            }
        } catch (e: Exception) {
            stopSelf()
        }
        if (call) listenForButton()
        return START_NOT_STICKY
    }
}
