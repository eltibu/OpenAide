package com.nexus.nexus_assistant

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle

/**
 * The phone's assistant (long-press power or home, a headset button) lands
 * here first, with no window of its own. It opens the small panel over the
 * app you're in ([AssistActivity]) when Settings > Phone and assistant asks
 * for that, or the full app otherwise.
 */
class AssistEntry : Activity() {
    companion object {
        private const val PREFS = "nexus_assist"

        fun overlayOn(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean("overlay", false)

        fun setOverlay(context: Context, on: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean("overlay", on).apply()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val target = if (overlayOn(this)) AssistActivity::class.java else MainActivity::class.java
        // Only the action goes on: any app can start this screen, so what it
        // put in the intent (shared files, a chat to open) must not reach the
        // panel, which other apps can't start themselves.
        val action = intent?.action.takeIf { it == Intent.ACTION_VOICE_COMMAND }
            ?: Intent.ACTION_ASSIST
        startActivity(
            Intent(action).setClass(this, target).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        finish()
    }
}
